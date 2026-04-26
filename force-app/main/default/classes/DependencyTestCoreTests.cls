@IsTest
private class DependencyTestCoreTests {

    @IsTest
    static void testStringUtilityAndHandler() {
        // StringUtility.formatName should upper-case non-null input
        String input  = 'my account';
        String output = StringUtility.formatName(input);
        System.assertEquals('MY ACCOUNT', output);

        // Simulate before-insert trigger calling AccountTriggerHandler.beforeInsert
        Account a = new Account(Name = 'test name');
        List<Account> records = new List<Account>{ a };

        Test.startTest();
        AccountTriggerHandler.beforeInsert(records);
        Test.stopTest();

        // The handler should safely run and update the Name
        System.assertEquals('TEST NAME', records[0].Name);
    }

    @IsTest
    static void testDependencyTestHelperQuery() {
        // Seed a Dependency_Test__c record so the helper query has something to find
        Dependency_Test__c dep = new Dependency_Test__c(
            Test_Text__c = 'hello'
        );
        insert dep;

        Test.startTest();
        List<Dependency_Test__c> results = DependencyTestHelper.getTestRecords();
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Helper should return at least one record');
        System.assertEquals(dep.Id, results[0].Id);
        System.assertEquals('hello', results[0].Test_Text__c);
    }
}
