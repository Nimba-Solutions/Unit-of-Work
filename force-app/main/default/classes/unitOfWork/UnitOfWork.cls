@SuppressWarnings('PMD')
/**
 * @description UnitOfWork
 */
public virtual class UnitOfWork {
    
    /**
     * Static transaction management.
     * Note: These static variables are transaction-scoped in Apex,
     * meaning they are automatically isolated between different requests
     * and automatically cleaned up at transaction boundaries.
     */
    private static UnitOfWork rootUow;
    private static Savepoint rootSavepoint;
    private static Boolean allowPartialSuccess = false;
    
    // State Management
    private final Map<Schema.SObjectType, List<SObject>> newRecords;
    private final Map<Id, SObject> dirtyRecords;
    private final Map<Id, SObject> deletedRecords;
    private final Map<String, List<DatabaseResult>> saveResults;
    private final List<RelationshipRecord> relationships;
    private final Map<Schema.SObjectType, Set<Schema.SObjectType>> dependencies;
    private final Database.DMLOptions dmlOptions;
    private Boolean isCommitted = false;
    
    /**
     * @description Allow partial success in a transaction. This must be called on the root UOW before any nested UOWs are created.
     * By default, if any UOW fails, everything is rolled back to the root savepoint.
     */
    public void allowPartialSuccess() {
        if (this !== rootUow) {
            throw new UnitOfWorkException('Only the root Unit of Work can allow partial success');
        }
        allowPartialSuccess = true;
    }
    
    // Constructor
    public UnitOfWork() {
        this(false);
    }
    
    public UnitOfWork(Boolean isTestMode) {
        this.newRecords = new Map<Schema.SObjectType, List<SObject>>();
        this.dirtyRecords = new Map<Id, SObject>();
        this.deletedRecords = new Map<Id, SObject>();
        this.saveResults = new Map<String, List<DatabaseResult>>();
        this.relationships = new List<RelationshipRecord>();
        this.dependencies = new Map<Schema.SObjectType, Set<Schema.SObjectType>>();
        
        // Configure DML Options
        this.dmlOptions = new Database.DMLOptions();
        if (isTestMode) {
            this.dmlOptions.optAllOrNone = false;
            if (Test.isRunningTest()) {
                // Only bypass validation rules in test context
                this.dmlOptions.DuplicateRuleHeader.AllowSave = true;
            }
        }

        // If this is the first UOW in the transaction, set it as root and create the root savepoint
        if (rootUow == null) {
            rootUow = this;
            rootSavepoint = Database.setSavepoint();
            allowPartialSuccess = false; // Reset to default for new root
        }
    }
    
    // Registration Methods
    public void registerNew(List<SObject> records) {
        if (records == null || records.isEmpty()) return;
        
        Schema.SObjectType sObjectType = records[0].getSObjectType();
        validateSObjectType(sObjectType);
        
        if (!newRecords.containsKey(sObjectType)) {
            newRecords.put(sObjectType, new List<SObject>());
        }
        newRecords.get(sObjectType).addAll(records);
    }
    
    public void registerNew(SObject record) {
        if (record == null) return;
        registerNew(new List<SObject>{record});
    }
    
    public void registerDirty(List<SObject> records) {
        if (records == null || records.isEmpty()) return;
        
        for (SObject record : records) {
            // Check if this record is already registered as new
            Boolean isAlreadyNew = false;
            if (record.Id == null) {
                Schema.SObjectType sObjectType = record.getSObjectType();
                if (newRecords.containsKey(sObjectType)) {
                    for (SObject newRecord : newRecords.get(sObjectType)) {
                        if (newRecord === record) {
                            isAlreadyNew = true;
                            break;
                        }
                    }
                }
            }
            
            // If it's already registered as new, we don't need to do anything
            // The changes will be included when the record is inserted
            if (!isAlreadyNew) {
                validateId(record);
                dirtyRecords.put(record.Id, record);
            }
        }
    }
    
    public void registerDirty(SObject record) {
        if (record == null) return;
        registerDirty(new List<SObject>{record});
    }
    
    public void registerDeleted(List<SObject> records) {
        if (records == null || records.isEmpty()) return;
        
        for (SObject record : records) {
            validateId(record);
            deletedRecords.put(record.Id, record);
        }
    }
    
    public void registerDeleted(SObject record) {
        if (record == null) return;
        registerDeleted(new List<SObject>{record});
    }
    
    /**
     * @description registerRelationship
     * @param record
     * @param relationshipField
     * @param relatedTo
     */
    public void registerRelationship(SObject record, Schema.SObjectField relationshipField, SObject relatedTo) {
        if (record == null || relationshipField == null || relatedTo == null) return;
        
        // Track the dependency
        Schema.SObjectType childType = record.getSObjectType();
        Schema.SObjectType parentType = relatedTo.getSObjectType();
        
        if (!dependencies.containsKey(childType)) {
            dependencies.put(childType, new Set<Schema.SObjectType>());
        }
        dependencies.get(childType).add(parentType);
        
        relationships.add(new RelationshipRecord(record, relationshipField, relatedTo));
    }
    
    /**
     * @description Register a junction record with two relationships
     * @param junctionType The SObject type of the junction object
     * @param sourceField The lookup field to the source record
     * @param targetField The lookup field to the target record
     * @param sourceRecord The source record
     * @param targetRecord The target record
     * @param existingJunction Optional - an existing junction record. If null, a new one will be created
     * @return The junction record (either newly created or the existing one passed in)
     */
    public SObject registerJunction(
        Schema.SObjectType junctionType,
        Schema.SObjectField sourceField,
        Schema.SObjectField targetField,
        SObject sourceRecord,
        SObject targetRecord,
        SObject existingJunction
    ) {
        if (junctionType == null || sourceField == null || targetField == null || 
            sourceRecord == null || targetRecord == null) {
            return null;
        }

        // Use provided junction record or create new one
        SObject junction = existingJunction != null ? existingJunction : junctionType.newSObject();
        
        // Only register new if this is a new junction record
        if (existingJunction == null) {
            registerNew(junction);
        }
        
        // Register both relationships
        registerRelationship(junction, sourceField, sourceRecord);
        registerRelationship(junction, targetField, targetRecord);

        return junction;
    }

    /**
     * @description Register a junction record with two relationships (legacy method)
     */
    public SObject registerJunction(
        Schema.SObjectType junctionType,
        Schema.SObjectField sourceField,
        Schema.SObjectField targetField,
        SObject sourceRecord,
        SObject targetRecord
    ) {
        return registerJunction(junctionType, sourceField, targetField, sourceRecord, targetRecord, null);
    }
    
    /**
     * @description Commit the unit of work
     */
    public void commitWork() {
        if (isCommitted) {
            throw new UnitOfWorkException('This Unit of Work has already been committed');
        }

        Savepoint localSavepoint;
        try {
            if (!beforeCommit()) {
                throw new UnitOfWorkException('Before commit validation failed');
            }

            // Create a local savepoint for this UOW's work
            localSavepoint = Database.setSavepoint();
            
            try {
                doWork();
                afterCommit();
                isCommitted = true;
            } catch (Exception e) {
                // Roll back just this UOW's work
                if (localSavepoint != null) {
                    Database.rollback(localSavepoint);
                }
                
                // Unless partial success is explicitly allowed, roll back everything on any failure
                if (!allowPartialSuccess) {
                    if (rootSavepoint != null) {
                        Database.rollback(rootSavepoint);
                    }
                    rootUow = null;
                    rootSavepoint = null;
                }
                
                // Preserve the original exception
                throw e;
            }
        } catch (Exception e) {
            handleError(e);

            // If this is the root UOW, always roll back everything
            if (this === rootUow && rootSavepoint != null) {
                Database.rollback(rootSavepoint);
                rootUow = null;
                rootSavepoint = null;
            }

            // Preserve stack trace by wrapping the original exception
            if (!(e instanceof UnitOfWorkException)) {
                UnitOfWorkException uowEx = new UnitOfWorkException(e.getMessage());
                uowEx.initCause(e);
                throw uowEx;
            }
            throw e;
        } finally {
            // If this is the root UOW, clear the transaction state
            if (this === rootUow) {
                rootUow = null;
                rootSavepoint = null;
                allowPartialSuccess = false; // Reset for next transaction
            }
        }
    }
    
    private void doWork() {
        Map<Schema.SObjectType, List<SObject>> insertedByType = new Map<Schema.SObjectType, List<SObject>>();
        List<UnitOfWorkException> allErrors = new List<UnitOfWorkException>();
        
        // Get ordered list of SObjects based on dependencies
        List<Schema.SObjectType> insertOrder = getInsertOrder();
        
        // 1. Insert new records in order
        for (Schema.SObjectType sObjectType : insertOrder) {
            if (newRecords.containsKey(sObjectType)) {
                List<SObject> recordsToInsert = newRecords.get(sObjectType);
                
                try {
                    // Process relationships for this specific type only
                    processRelationships(sObjectType);
                    
                    List<Database.SaveResult> results = Database.insert(recordsToInsert, dmlOptions);
                    List<DatabaseResult> convertedResults = new List<DatabaseResult>();
                    
                    // Check for any failures
                    List<String> errorMessages = new List<String>();
                    
                    for (Integer i = 0; i < results.size(); i++) {
                        DatabaseResult databaseResult = new DatabaseResult(results[i]);
                        convertedResults.add(databaseResult);
                        
                        if (!databaseResult.isSuccess()) {
                            for (Database.Error error : databaseResult.getErrors()) {
                                errorMessages.add(String.format('Record {0}: {1}', 
                                    new List<String>{String.valueOf(i), error.getMessage()}));
                            }
                        }
                    }
                    
                    saveResults.put('Insert_' + sObjectType, convertedResults);
                    
                    if (!errorMessages.isEmpty()) {
                        String errorMessage = String.format('Failed to insert {0} records:\n{1}', 
                            new List<String>{
                                String.valueOf(sObjectType),
                                String.join(errorMessages, '\n')
                            });
                        allErrors.add(new UnitOfWorkException(errorMessage));
                    } else {
                        // Only track successful inserts if no errors occurred
                        insertedByType.put(sObjectType, recordsToInsert);
                    }
                } catch (Exception e) {
                    allErrors.add(new UnitOfWorkException(
                        'Error processing ' + sObjectType + ': ' + e.getMessage()
                    ));
                }
            }
        }
        
        // 2. Update dirty records
        if (!dirtyRecords.isEmpty()) {
            try {
                List<Database.SaveResult> results = Database.update(dirtyRecords.values(), dmlOptions);
                List<DatabaseResult> convertedResults = new List<DatabaseResult>();
                List<String> errorMessages = new List<String>();
                
                for (Integer i = 0; i < results.size(); i++) {
                    DatabaseResult databaseResult = new DatabaseResult(results[i]);
                    convertedResults.add(databaseResult);
                    if (!databaseResult.isSuccess()) {
                        for (Database.Error error : databaseResult.getErrors()) {
                            errorMessages.add(String.format('Record {0}: {1}', 
                                new List<String>{String.valueOf(i), error.getMessage()}));
                        }
                    }
                }
                saveResults.put('Update', convertedResults);
                
                if (!errorMessages.isEmpty()) {
                    allErrors.add(new UnitOfWorkException(
                        'Failed to update records:\n' + String.join(errorMessages, '\n')
                    ));
                }
            } catch (Exception e) {
                allErrors.add(new UnitOfWorkException('Error during update: ' + e.getMessage()));
            }
        }
        
        // 3. Delete records
        if (!deletedRecords.isEmpty()) {
            try {
                List<Database.DeleteResult> results = Database.delete(deletedRecords.values(), true);
                List<DatabaseResult> convertedResults = new List<DatabaseResult>();
                List<String> errorMessages = new List<String>();
                
                for (Integer i = 0; i < results.size(); i++) {
                    DatabaseResult databaseResult = new DatabaseResult(results[i]);
                    convertedResults.add(databaseResult);
                    if (!databaseResult.isSuccess()) {
                        for (Database.Error error : databaseResult.getErrors()) {
                            errorMessages.add(String.format('Record {0}: {1}', 
                                new List<String>{String.valueOf(i), error.getMessage()}));
                        }
                    }
                }
                saveResults.put('Delete', convertedResults);
                
                if (!errorMessages.isEmpty()) {
                    allErrors.add(new UnitOfWorkException(
                        'Failed to delete records:\n' + String.join(errorMessages, '\n')
                    ));
                }
            } catch (Exception e) {
                allErrors.add(new UnitOfWorkException('Error during delete: ' + e.getMessage()));
            }
        }
        
        // If we collected any errors, throw them as a nested exception
        if (!allErrors.isEmpty()) {
            UnitOfWorkException rootException = new UnitOfWorkException(
                'Multiple errors occurred during transaction'
            );
            for (UnitOfWorkException error : allErrors) {
                rootException.addToExceptionTree(error);
            }
            throw rootException;
        }
    }
    
    protected virtual Boolean beforeCommit() {
        return true;
    }
    
    protected virtual void afterCommit() {
        if (!System.isFuture() && !System.isQueueable()) {
            // Only pass successful IDs to the queueable
            Map<String, Set<Id>> successfulIds = new Map<String, Set<Id>>();
            for (String key : saveResults.keySet()) {
                Set<Id> ids = new Set<Id>();
                for (DatabaseResult result : saveResults.get(key)) {
                    if (result.isSuccess()) {
                        ids.add(result.getId());
                    }
                }
                if (!ids.isEmpty()) {
                    successfulIds.put(key, ids);
                }
            }
            System.enqueueJob(new AfterCommitQueueable(successfulIds));
        }
    }
    
    protected virtual void handleError(Exception e) {
        logError(e);
        // If this is already a UnitOfWorkException, it will have proper nesting
        // If not, wrap it to maintain consistent error format
        if (!(e instanceof UnitOfWorkException)) {
            UnitOfWorkException uowEx = new UnitOfWorkException('Unexpected error in Unit of Work');
            uowEx.addToExceptionTree(new UnitOfWorkException(e.getMessage()));
            e = uowEx;
        }
        System.debug(LoggingLevel.ERROR, e.getMessage());
    }
    
    private void validateSObjectType(Schema.SObjectType sObjectType) {
        if (sObjectType == null) {
            throw new UnitOfWorkException('SObjectType cannot be null');
        }
        
        if (!sObjectType.getDescribe().isCreateable()) {
            throw new UnitOfWorkException('User does not have permission to create ' + sObjectType);
        }
    }
    
    private void validateId(SObject record) {
        if (record == null || record.Id == null) {
            throw new UnitOfWorkException('Record ID cannot be null');
        }
    }
    
    private void processRelationships(Schema.SObjectType sObjectType) {
        for (RelationshipRecord relationship : relationships) {
            if (relationship.record.getSObjectType() == sObjectType) {
                if (relationship.relatedTo.Id == null) {
                    throw new UnitOfWorkException(
                        'Parent record of type ' + relationship.relatedTo.getSObjectType() + 
                        ' must be inserted before child record of type ' + relationship.record.getSObjectType()
                    );
                }
                relationship.process();
            }
        }
    }
    
    private void handleDMLError(List<Database.Error> errors, String operation, Schema.SObjectType sObjectType) {
        String errorType = sObjectType != null ? operation + '_' + sObjectType : operation;
        List<String> errorMessages = new List<String>();
        
        for (Database.Error error : errors) {
            errorMessages.add(error.getMessage());
        }
        
        String errorMessage = String.format('DML {0} operation failed:\n{1}', 
            new List<String>{errorType, String.join(errorMessages, '\n')});
        
        logError(new UnitOfWorkException(errorMessage));
    }
    
    private void logError(Exception e) {
        String fullError = String.format('UnitOfWork Error: {0}\nStack Trace: {1}', 
            new List<String>{e.getMessage(), e.getStackTraceString()});
        System.debug(LoggingLevel.ERROR, fullError);
    }
    
    public Map<String, List<DatabaseResult>> getSaveResults() {
        return this.saveResults;
    }
    
    public class UnitOfWorkException extends Exception {
        @TestVisible
        private List<UnitOfWorkException> exceptionTree = new List<UnitOfWorkException>();
        
        public void addToExceptionTree(UnitOfWorkException e) {
            exceptionTree.add(e);
        }

        public String getExceptionTree() {
            return getExceptionTree(0);
        }

        private String getExceptionTree(Integer depth) {
            String indent = '  '.repeat(depth);
            String tree = indent + '└─ ' + getMessage().replace('\n', '\n' + indent + '   ');
            
            for (UnitOfWorkException branch : exceptionTree) {
                tree += '\n' + branch.getExceptionTree(depth + 1);
            }
            
            return tree;
        }

        // Add method to get base message without tree
        private String getBaseMessage() {
            return super.getMessage();
        }

        // New toJson method that returns clean nested arrays
        public String toJson() {
            return JSON.serialize(toList());
        }

        // Helper method to convert exception tree to nested lists
        public List<Object> toList() {
            List<Object> result = new List<Object>();
            result.add(getBaseMessage());
            
            if (!exceptionTree.isEmpty()) {
                List<Object> childErrors = new List<Object>();
                for (UnitOfWorkException branch : exceptionTree) {
                    childErrors.add(branch.toList());
                }
                result.add(childErrors);
            }
            
            return result;
        }
        
        public override String getMessage() {
            String result = super.getMessage();
            if (!exceptionTree.isEmpty()) {
                result += '\nException Tree:';
                for (UnitOfWorkException branch : exceptionTree) {
                    // Indent nested messages
                    result += '\n  ' + branch.getMessage().replace('\n', '\n  ');
                }
            }
            return result;
        }

        public void logExceptionTree() {
            logExceptionTree(LoggingLevel.ERROR);
        }

        public void logExceptionTree(LoggingLevel level) {
            System.debug(level, '\n=== UnitOfWork Exception Tree ===\n' + getExceptionTree() + '\n===============================');
        }
    }
    
    private class AfterCommitQueueable implements System.Queueable {
        private final Map<String, Set<Id>> successfulIds;
        
        public AfterCommitQueueable(Map<String, Set<Id>> successfulIds) {
            this.successfulIds = successfulIds;
        }
        
        public void execute(System.QueueableContext context) {
            for (String operation : successfulIds.keySet()) {
                System.debug(LoggingLevel.INFO, 'Processing ' + operation + ' results: ' + successfulIds.get(operation));
            }
        }
    }
    
    public class DatabaseResult {
        private final Id recordId;
        private final Boolean isSuccessful;
        private final List<Database.Error> errors;
        
        public DatabaseResult(Database.SaveResult sr) {
            this.recordId = sr.getId();
            this.isSuccessful = sr.isSuccess();
            this.errors = sr.getErrors();
        }
        
        public DatabaseResult(Database.DeleteResult dr) {
            this.recordId = dr.getId();
            this.isSuccessful = dr.isSuccess();
            this.errors = dr.getErrors();
        }
        
        public Id getId() { return recordId; }
        public Boolean isSuccess() { return isSuccessful; }
        public List<Database.Error> getErrors() { return errors; }
    }
    
    private class RelationshipRecord {
        private final SObject record;
        private final Schema.SObjectField relationshipField;
        private final SObject relatedTo;
        
        public RelationshipRecord(SObject record, Schema.SObjectField relationshipField, SObject relatedTo) {
            this.record = record;
            this.relationshipField = relationshipField;
            this.relatedTo = relatedTo;
        }
        
        public void process() {
            // The parent record should have an Id by now since we process in order
            record.put(relationshipField, relatedTo.Id);
        }
    }
    
    private List<Schema.SObjectType> getInsertOrder() {
        List<Schema.SObjectType> result = new List<Schema.SObjectType>();
        Set<Schema.SObjectType> visited = new Set<Schema.SObjectType>();
        Set<Schema.SObjectType> processing = new Set<Schema.SObjectType>();
        
        for (Schema.SObjectType sObjectType : newRecords.keySet()) {
            visitNode(sObjectType, visited, processing, result);
        }
        
        return result;
    }
    
    private void visitNode(
        Schema.SObjectType sObjectType, 
        Set<Schema.SObjectType> visited, 
        Set<Schema.SObjectType> processing, 
        List<Schema.SObjectType> result
    ) {
        if (processing.contains(sObjectType)) {
            throw new UnitOfWorkException('Circular dependency detected for ' + sObjectType);
        }
        
        if (visited.contains(sObjectType)) {
            return;
        }
        
        processing.add(sObjectType);
        
        // Visit all dependencies first
        if (dependencies.containsKey(sObjectType)) {
            for (Schema.SObjectType dependency : dependencies.get(sObjectType)) {
                if (newRecords.containsKey(dependency)) {
                    visitNode(dependency, visited, processing, result);
                }
            }
        }
        
        processing.remove(sObjectType);
        visited.add(sObjectType);
        result.add(sObjectType);
    }
} 