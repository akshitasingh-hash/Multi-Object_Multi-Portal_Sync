/**
 * In-memory buffer for failed operations. Rows are collected during the
 * callout loop and written with a single insert AFTER all callouts in the
 * transaction (see PortalRouter note). The reconciliation batch can later retry
 * these, and they give you an audit trail of what didn't sync.
 *
 * Each row is tagged with the SObject it came from, so a single dead-letter
 * table serves every synced object. Record_Id__c holds the record id for any
 * object; Contact_Id__c is a Contact-only lookup kept for backward compatibility
 * and populated only for Contact rows.
 */
public with sharing class PortalSyncDeadLetter {

    private static List<PortalSyncDeadLetter__c> buffer = new List<PortalSyncDeadLetter__c>();

    public static void log(String sObjectName, String sfId, String portal, String operation, String message) {
        PortalSyncDeadLetter__c row = new PortalSyncDeadLetter__c(
            SObject_Name__c = sObjectName,
            Record_Id__c    = sfId,
            Portal__c       = portal,
            Operation__c    = operation,
            Error__c        = (message != null && message.length() > 255) ? message.substring(0, 255) : message
        );
        // Contact_Id__c is a Contact lookup -- only legal to set for Contact ids.
        //if (sObjectName == 'Contact') row.Contact_Id__c = sfId;
        buffer.add(row);
    }

    /** Call once, after every callout in the transaction has completed. */
    public static void flush() {
        if (!buffer.isEmpty()) {
            insert buffer;
            buffer.clear();
        }
    }
}
