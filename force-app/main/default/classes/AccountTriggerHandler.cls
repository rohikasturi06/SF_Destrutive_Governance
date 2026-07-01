public with sharing class AccountTriggerHandler {
    public static void beforeInsert(List<Account> newAccounts) {
        for (Account acc : newAccounts) {
            if (acc.Name != null) {
                // Trim whitespace and normalize casing (previously delegated to
                // StringUtility.formatName; inlined so this class is self-contained
                // and does not depend on a class that may not be in the target org).
                acc.Name = acc.Name.trim().toUpperCase();
            }
        }
    }
}
