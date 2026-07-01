@IsTest
private class DependencyTestHelperTest {

    // Covers both execution paths of DependencyTestHelper.getTestRecords():
    //   - the guarded early-return when Dependency_Test__c is absent, and
    //   - the dynamic SOQL path when the object exists.
    // Only one path is exercisable per org (the object either exists or not),
    // so the test adapts to the running org's state via describe.
    @IsTest
    static void getTestRecords_behavesForCurrentOrgState() {
        Schema.SObjectType dependencyType = Schema.getGlobalDescribe().get('Dependency_Test__c');

        if (dependencyType == null) {
            // Object removed from this org: helper must degrade gracefully.
            Test.startTest();
            List<SObject> results = DependencyTestHelper.getTestRecords();
            Test.stopTest();

            System.assertNotEquals(null, results, 'Helper must never return null');
            System.assertEquals(0, results.size(), 'Helper should return an empty list when the object is unavailable');
            return;
        }

        // Object exists: seed a record dynamically, then confirm the query finds it.
        SObject dep = dependencyType.newSObject();
        dep.put('Test_Text__c', 'unit-test-value');
        insert dep;

        Test.startTest();
        List<SObject> results = DependencyTestHelper.getTestRecords();
        Test.stopTest();

        System.assertNotEquals(null, results, 'Helper must never return null');
        System.assert(!results.isEmpty(), 'Helper should return at least one record when data exists');
        System.assertEquals((Id) dep.get('Id'), (Id) results[0].get('Id'), 'Returned Id should match the seeded record');
        System.assertEquals('unit-test-value', (String) results[0].get('Test_Text__c'), 'Returned Test_Text__c should match the seeded value');
    }
}
