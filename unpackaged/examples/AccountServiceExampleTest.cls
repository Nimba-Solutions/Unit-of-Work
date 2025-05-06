@isTest
public with sharing class AccountServiceExampleTest {
    @isTest
    public static void getAccount(){
        Test.startTest();
        Account account = new Account();
        account.Name = 'Test Account';
        insert account;

        AccountServiceExample accountService = new AccountServiceExample();
        Account accountResult = accountService.getAccountById(account.Id);
        System.assertEquals(account.Name, accountResult.Name);
        Test.stopTest();
    }

    @isTest
    public static void getAccounts(){
        Test.startTest();
        AccountServiceExample accountService = new AccountServiceExample();
        List<Account> accountResult = accountService.getAllAccounts(1);
        System.assertEquals(0, accountResult.size());
        Test.stopTest();
    }

    @isTest
    public static void createAccount() {
        Test.startTest();
        Account account = new Account();
        account.Name = 'Test Account';

        AccountServiceExample accountService = new AccountServiceExample();
        Account accountResult = accountService.createAccount(account);
        System.assertEquals(account.Name, accountResult.Name);
        Test.stopTest();
    }

    @isTest
    public static void updateAccount() {
        Test.startTest();
        Account account = new Account();
        account.Name = 'Test Account';
        insert account;

        AccountServiceExample accountService = new AccountServiceExample();
        Account accountResult = accountService.updateAccount(account);
        System.assertEquals(account.Name, accountResult.Name);
        Test.stopTest();
    }

    @isTest
    public static void deleteAccount() {
        Test.startTest();
        Account account = new Account();
        account.Name = 'Test Account';
        insert account;

        AccountServiceExample accountService = new AccountServiceExample();
        accountService.deleteAccount(account);
        Test.stopTest();
        List<Account> accts = [SELECT Id FROM Account WHERE Id = :account.Id LIMIT 1];        
        System.assertEquals(0, accts.size());
    }
}