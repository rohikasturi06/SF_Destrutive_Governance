@IsTest
private class AccountTriggerHandlerTest {

    // Covers the name != null path: values are trimmed and upper-cased.
    @IsTest
    static void beforeInsert_trimsAndUppercasesName() {
        List<Account> accounts = new List<Account>{
            new Account(Name = '  acme corp  '),
            new Account(Name = 'Test')
        };

        Test.startTest();
        AccountTriggerHandler.beforeInsert(accounts);
        Test.stopTest();

        System.assertEquals('ACME CORP', accounts[0].Name, 'Name should be trimmed and upper-cased');
        System.assertEquals('TEST', accounts[1].Name, 'Name should be upper-cased');
    }

    // Covers the null-guard path: a null name is left untouched (no exception).
    @IsTest
    static void beforeInsert_handlesNullName() {
        List<Account> accounts = new List<Account>{ new Account() };

        Test.startTest();
        AccountTriggerHandler.beforeInsert(accounts);
        Test.stopTest();

        System.assertEquals(null, accounts[0].Name, 'A null name must remain null without error');
    }
}
