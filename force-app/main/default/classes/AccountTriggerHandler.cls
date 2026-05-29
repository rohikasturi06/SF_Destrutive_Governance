public with sharing class AccountTriggerHandler {
    public static void beforeInsert(List<Account> accounts) {
        for (Account account : accounts) {
            account.Name = account.Name.trim();
        }
    }
}