public with sharing class DependencyTestHelper {
    public static List<Dependency_Test__c> getTestRecords() {
        return [SELECT Id, Test_Text__c FROM Dependency_Test__c LIMIT 10];
    }
}
