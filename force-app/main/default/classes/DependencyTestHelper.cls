public with sharing class DependencyTestHelper {
    public static List<SObject> getTestRecords() {
        Schema.SObjectType dependencyType = Schema.getGlobalDescribe().get('Dependency_Test__c');
        if (dependencyType == null) {
            return new List<SObject>();
        }

        return Database.query('SELECT Id, Test_Text__c FROM Dependency_Test__c LIMIT 10');
    }
}
    