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
        Schema.SObjectType dependencyType = Schema.getGlobalDescribe().get('Dependency_Test__c');

        if (dependencyType == null) {
            Test.startTest();
            List<SObject> emptyResults = DependencyTestHelper.getTestRecords();
            Test.stopTest();
            System.assertEquals(0, emptyResults.size(), 'Helper should return empty when object is unavailable');
            return;
        }

        // Seed a Dependency_Test__c record so the helper query has something to find
        SObject dep = dependencyType.newSObject();
        dep.put('Test_Text__c', 'hello');
        insert dep;

        Test.startTest();
        List<SObject> results = DependencyTestHelper.getTestRecords();
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Helper should return at least one record');
        System.assertEquals((Id)dep.get('Id'), (Id)results[0].get('Id'));
        System.assertEquals('hello', (String)results[0].get('Test_Text__c'));
    }
}
