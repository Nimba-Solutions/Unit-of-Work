/**
 * @description Base class example for service layer implementations that handle database operations.
 * This class is marked 'without sharing' intentionally as sharing rules should be enforced
 * by the concrete service implementations. This allows subclasses to explicitly define their
 * own security model using 'with sharing' or 'inherited sharing' as appropriate for their use case.
 * 
 * The class provides standard CRUD operations with transaction control through the UnitOfWork pattern.
 * Transaction management is completely encapsulated - developers only need to:
 * 1. Extend this class
 * 2. Implement getSObjectType()
 * 3. Use the provided CRUD methods
 * 
 * For complex operations involving multiple steps:
 * 1. Use getUnitOfWork() to get the transaction context
 * 2. Register all operations
 * 3. Call commitWork() when ready
 * 
 * The UnitOfWork will handle:
 * - Proper ordering of DML operations
 * - Relationship management
 * - Full transaction control
 * - Detailed error tracking
 */
@SuppressWarnings('PMD')
public without sharing abstract class UowService {
    protected abstract SObjectType getSObjectType();
    protected final UnitOfWork uow;

    /**
     * @description UowService constructor
     * Initializes a new UnitOfWork instance for transaction management
     */
    public UowService() {
        this.uow = new UnitOfWork();
    }

    /**
     * @description UowService constructor that accepts an existing UnitOfWork
     * Use this constructor when you need to:
     * 1. Coordinate operations across multiple services in a single transaction
     * 2. Share the same transaction context between different services
     * 3. Control transaction boundaries from a higher level
     * 4. Inject a specific UnitOfWork instance for testing
     * 
     * Example:
     * UnitOfWork uow = new UnitOfWork();
     * AccountService accountService = new AccountService(uow);
     * ContactService contactService = new ContactService(uow);
     * // Both services will share the same transaction
     * 
     * @param unitOfWork An existing UnitOfWork instance to use for this service
     */
    public UowService(UnitOfWork unitOfWork) {
        this.uow = unitOfWork;
    }

    // Query operations
    /**
     * @description Get record by Salesforce Id
     * @param recordId
     * @return SObject
     */
    public SObject getById(Id recordId) {
        string sObjectType = String.escapeSingleQuotes(String.valueOf(getSObjectType()));
        String query = 'SELECT Id, Name FROM ' + sObjectType + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> results = Database.query(query);
        return results.isEmpty() ? null : results[0];
    }

    /**
     * @description Get the first n records
     * @param limitCount
     * @return List<SObject>
     */
    public List<SObject> getAll(Integer limitCount) {
        string sObjectType = String.escapeSingleQuotes(String.valueOf(getSObjectType()));
        String query = 'SELECT Id, Name FROM ' + sObjectType + ' LIMIT :limitCount';
        return Database.query(query);
    }

    // Single record operations
    /**
     * @description Create a single record and commit the transaction
     * @param record The record to create
     * @return The created record
     * @throws UnitOfWork.UnitOfWorkException if record is null or wrong SObject type
     */
    public SObject createRecord(SObject record) {
        validateRecord(record);
        uow.registerNew(record);
        uow.commitWork();
        return record;
    }

    /**
     * @description Update a single record and commit the transaction
     * @param record The record to update
     * @return The updated record
     * @throws UnitOfWork.UnitOfWorkException if record is null, has no Id, or wrong SObject type
     */
    public SObject updateRecord(SObject record) {
        validateRecord(record);
        uow.registerDirty(record);
        uow.commitWork();
        return record;
    }

    /**
     * @description Delete a single record and commit the transaction
     * @param record The record to delete
     * @throws UnitOfWork.UnitOfWorkException if record is null, has no Id, or wrong SObject type
     */
    public void deleteRecord(SObject record) {
        validateRecord(record);
        uow.registerDeleted(record);
        uow.commitWork();
    }

    // Bulk operations
    /**
     * @description Create multiple records and commit the transaction
     * @param records The records to create
     * @return The created records
     * @throws UnitOfWork.UnitOfWorkException if any record is null or wrong SObject type
     */
    public List<SObject> createRecords(List<SObject> records) {
        validateRecords(records);
        uow.registerNew(records);
        uow.commitWork();
        return records;
    }

    /**
     * @description Update multiple records and commit the transaction
     * @param records The records to update
     * @return The updated records
     * @throws UnitOfWork.UnitOfWorkException if any record is null, has no Id, or wrong SObject type
     */
    public List<SObject> updateRecords(List<SObject> records) {
        validateRecords(records);
        uow.registerDirty(records);
        uow.commitWork();
        return records;
    }

    /**
     * @description Delete multiple records and commit the transaction
     * @param records The records to delete
     * @throws UnitOfWork.UnitOfWorkException if any record is null, has no Id, or wrong SObject type
     */
    public void deleteRecords(List<SObject> records) {
        validateRecords(records);
        uow.registerDeleted(records);
        uow.commitWork();
    }

    // Transaction control
    /**
     * @description Allow partial success across nested UnitOfWork instances
     * 
     * By default, if any UnitOfWork in a transaction fails, everything is rolled back
     * to the root savepoint. When partial success is allowed, a failed UnitOfWork will
     * only roll back its own operations, allowing other UnitOfWork instances in the
     * transaction to commit successfully.
     * 
     * Note: 
     * - This only affects behavior across DIFFERENT UnitOfWork instances
     * - Within a single UnitOfWork, all operations still succeed or fail together
     * - This must be called on the ROOT UnitOfWork before any nested instances are created
     * - Only the root UnitOfWork can allow partial success
     */
    public void allowPartialSuccess() {
        uow.allowPartialSuccess();
    }

    // Relationship operations
    /**
     * @description Register a relationship between two records
     * @param record The child record
     * @param relationshipField The lookup field on the child
     * @param relatedTo The parent record
     */
    protected void registerRelationship(SObject record, Schema.SObjectField relationshipField, SObject relatedTo) {
        uow.registerRelationship(record, relationshipField, relatedTo);
    }

    /**
     * @description Register a junction record between two records
     * @param junctionType The SObject type of the junction object
     * @param sourceField The lookup field to the source record
     * @param targetField The lookup field to the target record
     * @param sourceRecord The source record
     * @param targetRecord The target record
     * @return The created junction record
     */
    protected SObject registerJunction(
        Schema.SObjectType junctionType,
        Schema.SObjectField sourceField,
        Schema.SObjectField targetField,
        SObject sourceRecord,
        SObject targetRecord
    ) {
        return uow.registerJunction(junctionType, sourceField, targetField, sourceRecord, targetRecord);
    }

    /**
     * @description Get the results of the last commit operation
     * This includes success/failure status and error details for each record
     * @return Map of operation type to list of database results
     */
    public Map<String, List<UnitOfWork.DatabaseResult>> getSaveResults() {
        return uow.getSaveResults();
    }

    /**
     * @description Commit any pending operations in the UnitOfWork
     * This will:
     * 1. Process all registered operations in the correct order
     * 2. Handle relationships between records
     * 3. Roll back on any errors (unless partial success is allowed)
     * 4. Provide detailed error information if anything fails
     * @throws UnitOfWork.UnitOfWorkException with a detailed exception tree if any operations fail
     */
    public void commitWork() {
        uow.commitWork();
    }

    // Validation helpers
    private void validateRecord(SObject record) {
        if (record == null) {
            throw new UnitOfWork.UnitOfWorkException('Record cannot be null');
        }
        if (record.getSObjectType() != getSObjectType()) {
            throw new UnitOfWork.UnitOfWorkException(
                String.format('Invalid SObject type. Expected {0} but got {1}', 
                    new List<String>{
                        String.valueOf(getSObjectType()),
                        String.valueOf(record.getSObjectType())
                    }
                )
            );
        }
    }

    private void validateRecords(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            throw new UnitOfWork.UnitOfWorkException('Records list cannot be null or empty');
        }
        for (SObject record : records) {
            validateRecord(record);
        }
    }
} 