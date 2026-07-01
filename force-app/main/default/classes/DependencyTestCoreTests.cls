@IsTest
private class DependencyTestCoreTests {

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
