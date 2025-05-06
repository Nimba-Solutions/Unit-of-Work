/**
 * @description AccountServiceExample
 */
public class AccountServiceExample extends UowService {
    protected override SObjectType getSObjectType() {
        return Account.SObjectType;
    }

    /**
     * Type-safe Wrapper Methods
     * 
     * These are optional but recommended.
     * 
     * UowService works with generic SObject, which means:
     * 1. You could cast results like: (Account)getById(id)
     * 2. Passing a Contact would compile but fail at runtime
     * 
     * These wrapper methods:
     * 1. Enforce the correct sObject Type
     * 2. Clearly show what operations are available in your IDE
     */  

    /**
     * @description Get account record by Salesforce Id
     * @param recordId
     * @return Account
     */
    public Account getAccountById(Id recordId) {
        return (Account)getById(recordId);
    }

    /**
     * @description Get the first n account records
     * @param limitCount
     * @return List<Account>
     */
    public List<Account> getAllAccounts(Integer limitCount) {
        return (List<Account>)getAll(limitCount);
    }

    /**
     * @description Create account record using unit of work and return the created record. Rollback if any error occurs.
     * @param record
     * @return Account
     */
    public Account createAccount(Account record) {
        return (Account)createRecord(record);
    }

    /**
     * @description Update account record using unit of work and return the updated record. Rollback if any error occurs.
     * @param record
     * @return Account
     */
    public Account updateAccount(Account record) {
        return (Account)updateRecord(record);
    }

    /**
     * @description Delete account record using unit of work. Rollback if any error occurs.
     * @param record
     */
    public void deleteAccount(Account record) {
        deleteRecord(record);
    }

    /**
     * Complex Example
     * 
     * This shows how to:
     * 1. Create an Account and Contact in one transaction
     * 2. Set up their relationship using UnitOfWork directly
     * 3. Commit everything at once
     */

    /**
     * @description Create account record with contact using unit of work and return the created record. Rollback if any error occurs.
     * @param accountName
     * @param contactLastName
     * @return Account
     */
    public Account createAccountWithContact(String accountName, String contactLastName) {
        // Add timestamp to make names unique
        Long timestamp = System.now().getTime();
        
        // Create account without committing
        Account acc = new Account(
            Name = accountName + ' ' + timestamp
        );
        uow.registerNew(acc);

        // Create contact without committing
        Contact con = new Contact(
            LastName = contactLastName + ' ' + timestamp,
            Email = contactLastName.deleteWhitespace() + '.' + timestamp + '@example.com'
        );
        uow.registerNew(con);
        uow.registerRelationship(con, Contact.AccountId, acc);
        
        // Commit everything
        commitWork();

        // Return the Account 
        return acc;
    }
} 