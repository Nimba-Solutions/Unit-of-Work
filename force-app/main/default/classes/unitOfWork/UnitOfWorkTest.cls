@SuppressWarnings('PMD')
@IsTest
private class UnitOfWorkTest {
    private static Integer counter = 0;
    
    private static String getUniqueName() {
        counter++;
        return 'Test_' + counter + '_' + Crypto.getRandomInteger();
    }
    
    private static String getUniqueEmail() {
        counter++;
        return 'test' + counter + '_' + Crypto.getRandomInteger() + '@test.com';
    }
    
    @IsTest
    static void testBasicDMLOperations() {
        // Given
        UnitOfWork uow = new UnitOfWork(true);
        Account acc = new Account(Name = getUniqueName());
        Contact con = new Contact(LastName = getUniqueName(), Email = getUniqueEmail());
        
        // When
        Test.startTest();
        uow.registerNew(acc);
        uow.registerNew(con);
        uow.registerRelationship(con, Contact.AccountId, acc);
        uow.commitWork();
        Test.stopTest();
        
        // Then
        Account createdAcc = [SELECT Id, (SELECT Id FROM Contacts) FROM Account LIMIT 1];
        System.assertNotEquals(null, createdAcc.Id, 'Account should be created');
        System.assertEquals(1, createdAcc.Contacts.size(), 'Contact should be related to Account');
    }
    
    @IsTest
    static void testAllOrNoneBehavior() {
        // Given
        UnitOfWork uow = new UnitOfWork();
        Account invalidAccount = new Account(); // Missing required Name field

        // When
        uow.registerNew(invalidAccount);
        try {
            uow.commitWork();
            System.assert(false, 'Should have thrown an exception');
        } catch (UnitOfWork.UnitOfWorkException e) {
            // Then
            String expectedMessage = 'Multiple errors occurred during transaction';
            System.assertEquals(expectedMessage, e.getMessage().split('\n')[0], 
                'Should get correct error message');
            System.assert(e.getMessage().contains('Required fields are missing: [Name]'), 
                'Error should mention missing required field');
        }
    }
    
    @IsTest
    static void testNestedTransactionsWithoutPartialSuccess() {
        Test.startTest();
        
        try {
            // Given - Root UOW
            UnitOfWork root = new UnitOfWork(true);
            Account rootAcc = new Account(Name = getUniqueName());
            root.registerNew(rootAcc);
            
            // First nested UOW succeeds
            UnitOfWork nested1 = new UnitOfWork(true);
            Contact con = new Contact(
                LastName = getUniqueName(), 
                Email = getUniqueEmail(),
                AccountId = rootAcc.Id
            );
            nested1.registerNew(con);
            nested1.commitWork();
            
            // Second nested UOW fails
            UnitOfWork nested2 = new UnitOfWork(true);
            Contact invalidContact = new Contact(); // Missing required fields
            nested2.registerNew(invalidContact);
            
            try {
                nested2.commitWork();
                System.assert(false, 'Should have thrown an exception');
            } catch(Exception e) {
                // Expected - this should trigger a rollback of everything
                throw e; // Re-throw to ensure root transaction rolls back
            }
            
            root.commitWork(); // Should not reach here
            System.assert(false, 'Should not reach here');
            
        } catch(Exception e) {
            // Expected
        }
        
        Test.stopTest();
        
        // Then - everything should be rolled back
        List<Account> accounts = [SELECT Id FROM Account];
        List<Contact> contacts = [SELECT Id FROM Contact];
        
        System.assertEquals(0, accounts.size(), 'No accounts should exist');
        System.assertEquals(0, contacts.size(), 'No contacts should exist');
    }
    
    @IsTest
    static void testNestedTransactionsWithPartialSuccess() {
        // Given
        UnitOfWork root = new UnitOfWork(true);
        root.allowPartialSuccess();
        Account rootAcc = new Account(Name = getUniqueName());
        root.registerNew(rootAcc);
        
        // When
        Test.startTest();
        
        // First nested UOW succeeds
        UnitOfWork nested1 = new UnitOfWork(true);
        Contact con = new Contact(LastName = getUniqueName(), Email = getUniqueEmail());
        nested1.registerNew(con);
        nested1.commitWork();
        
        // Second nested UOW fails
        UnitOfWork nested2 = new UnitOfWork(true);
        Contact invalidContact = new Contact(); // Missing required fields
        nested2.registerNew(invalidContact);
        
        try {
            nested2.commitWork();
            System.assert(false, 'Should have thrown an exception');
        } catch(Exception e) {
            // Expected
        }
        
        // Root UOW commits
        root.commitWork();
        
        Test.stopTest();
        
        // Then - successful operations should remain
        System.assertEquals(1, [SELECT COUNT() FROM Account], 'Root account should exist');
        System.assertEquals(1, [SELECT COUNT() FROM Contact], 'First contact should exist');
    }
    
    @IsTest
    static void testComplexRelationships() {
        // Given
        UnitOfWork uow = new UnitOfWork(true);
        
        Account acc = new Account(Name = getUniqueName());
        Contact con = new Contact(LastName = getUniqueName(), Email = getUniqueEmail());
        Opportunity opp = new Opportunity(
            Name = getUniqueName(),
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        
        // When
        Test.startTest();
        uow.registerNew(acc);
        uow.registerNew(con);
        uow.registerNew(opp);
        
        uow.registerRelationship(con, Contact.AccountId, acc);
        uow.registerRelationship(opp, Opportunity.AccountId, acc);
        
        // Create junction record
        uow.registerJunction(
            OpportunityContactRole.SObjectType,
            OpportunityContactRole.ContactId,
            OpportunityContactRole.OpportunityId,
            con,
            opp
        );
        
        uow.commitWork();
        Test.stopTest();
        
        // Then
        Account createdAcc = [
            SELECT Id, 
                   (SELECT Id FROM Contacts), 
                   (SELECT Id FROM Opportunities)
            FROM Account 
            LIMIT 1
        ];
        
        System.assertEquals(1, createdAcc.Contacts.size(), 'Should have one contact');
        System.assertEquals(1, createdAcc.Opportunities.size(), 'Should have one opportunity');
        
        List<OpportunityContactRole> roles = [SELECT Id FROM OpportunityContactRole];
        System.assertEquals(1, roles.size(), 'Should have created junction record');
    }
    
    @IsTest
    static void testDirtyRecords() {
        // Given
        UnitOfWork uow = new UnitOfWork(true);
        Account acc = new Account(Name = getUniqueName());
        
        // When
        Test.startTest();
        uow.registerNew(acc);
        uow.commitWork();
        
        // Update the account
        acc.Name = getUniqueName();
        UnitOfWork updateUow = new UnitOfWork(true);
        updateUow.registerDirty(acc);
        updateUow.commitWork();
        Test.stopTest();
        
        // Then
        Account updated = [SELECT Name FROM Account WHERE Id = :acc.Id];
        System.assertEquals(acc.Name, updated.Name, 'Account name should be updated');
    }
    
    @IsTest
    static void testDeleteRecords() {
        // Given
        Account acc = new Account(Name = getUniqueName());
        insert acc;
        
        // When
        Test.startTest();
        UnitOfWork uow = new UnitOfWork(true);
        uow.registerDeleted(acc);
        uow.commitWork();
        Test.stopTest();
        
        // Then
        System.assertEquals(0, [SELECT COUNT() FROM Account], 'Account should be deleted');
    }
    
    @IsTest
    static void testOnlyRootCanAllowPartialSuccess() {
        // Given
        UnitOfWork root = new UnitOfWork(true);
        UnitOfWork nested = new UnitOfWork(true);
        
        // When
        Test.startTest();
        root.allowPartialSuccess(); // Should work
        
        try {
            nested.allowPartialSuccess(); // Should fail
            System.assert(false, 'Should have thrown an exception');
        } catch(UnitOfWork.UnitOfWorkException e) {
            // Then
            System.assert(e.getMessage().contains('Only the root Unit of Work'), 
                'Should get correct error message');
        }
        Test.stopTest();
    }
    
    @IsTest
    static void testCircularDependency() {
        Test.startTest();
        
        // Given
        UnitOfWork uow = new UnitOfWork(true);
        Account acc1 = new Account(Name = getUniqueName());
        Account acc2 = new Account(Name = getUniqueName());
        
        // Create circular dependency
        uow.registerNew(acc1);
        uow.registerNew(acc2);
        uow.registerRelationship(acc1, Account.ParentId, acc2);
        uow.registerRelationship(acc2, Account.ParentId, acc1);
        
        // When
        try {
            uow.commitWork();
            System.assert(false, 'Should have thrown an exception');
        } catch(UnitOfWork.UnitOfWorkException e) {
            // Then
            System.assert(e.getMessage().contains('Circular dependency'), 
                'Should detect circular dependency');
        }
        
        Test.stopTest();
        
        // Verify nothing was committed
        System.assertEquals(0, [SELECT COUNT() FROM Account], 'No accounts should be created');
    }
    
    @IsTest
    static void testExceptionToJson() {
        // Given - Create a nested exception structure
        UnitOfWork.UnitOfWorkException root = new UnitOfWork.UnitOfWorkException('Multiple errors occurred during transaction');
        UnitOfWork.UnitOfWorkException accountError = new UnitOfWork.UnitOfWorkException('Failed to insert Account records');
        UnitOfWork.UnitOfWorkException contactError = new UnitOfWork.UnitOfWorkException('Failed to insert Contact records');
        
        accountError.addToExceptionTree(new UnitOfWork.UnitOfWorkException('Record 0: Required fields are missing: [Name]'));
        accountError.addToExceptionTree(new UnitOfWork.UnitOfWorkException('Record 1: Invalid email address: test@invalid'));
        
        contactError.addToExceptionTree(new UnitOfWork.UnitOfWorkException('Record 0: Please enter either a Phone number or an Email address'));
        contactError.addToExceptionTree(new UnitOfWork.UnitOfWorkException('Record 1: Parent Account was not inserted'));
        
        root.addToExceptionTree(accountError);
        root.addToExceptionTree(contactError);

        // When
        String jsonResult = root.toJson();
        List<Object> parsed = (List<Object>)JSON.deserializeUntyped(jsonResult);

        // Then - verify root level
        System.assertEquals('Multiple errors occurred during transaction', parsed[0], 'Root message should match');
        List<Object> rootErrors = (List<Object>)parsed[1];
        System.assertEquals(2, rootErrors.size(), 'Should have two child errors');

        // Verify Account error branch
        List<Object> accountBranch = (List<Object>)rootErrors[0];
        System.assertEquals('Failed to insert Account records', accountBranch[0], 'Account error message should match');
        List<Object> accountErrors = (List<Object>)accountBranch[1];
        System.assertEquals(2, accountErrors.size(), 'Account should have two errors');
        System.assertEquals('Record 0: Required fields are missing: [Name]', ((List<Object>)accountErrors[0])[0], 'First account error should match');
        System.assertEquals('Record 1: Invalid email address: test@invalid', ((List<Object>)accountErrors[1])[0], 'Second account error should match');

        // Verify Contact error branch
        List<Object> contactBranch = (List<Object>)rootErrors[1];
        System.assertEquals('Failed to insert Contact records', contactBranch[0], 'Contact error message should match');
        List<Object> contactErrors = (List<Object>)contactBranch[1];
        System.assertEquals(2, contactErrors.size(), 'Contact should have two errors');
        System.assertEquals('Record 0: Please enter either a Phone number or an Email address', ((List<Object>)contactErrors[0])[0], 'First contact error should match');
        System.assertEquals('Record 1: Parent Account was not inserted', ((List<Object>)contactErrors[1])[0], 'Second contact error should match');
    }
}