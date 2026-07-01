public with sharing class AccountTriggerHandler {
    public static void beforeInsert(List<Account> newAccounts) {
        for (Account acc : newAccounts) {
            acc.Name = StringUtility.formatName(acc.Name?.trim());
        }
    }
}