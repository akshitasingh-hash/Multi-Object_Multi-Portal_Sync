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
  /** Error__c is a LongTextArea(1000), so this is the field's real capacity.
   *  It used to truncate at 255 -- a leftover from when the field was Text --
   *  which cost the most useful part of a long DML or HubSpot validation
   *  message, exactly the messages that need reading. */
  private static final Integer ERROR_MAX = 1000;

  private static List<PortalSyncDeadLetter__c> buffer = new List<PortalSyncDeadLetter__c>();

  public static void log(
    String sObjectName,
    String sfId,
    String portal,
    String operation,
    String message
  ) {
    PortalSyncDeadLetter__c row = new PortalSyncDeadLetter__c(
      SObject_Name__c = sObjectName,
      Record_Id__c = sfId,
      Portal__c = portal,
      Operation__c = operation,
      Error__c = (message != null &&
        message.length() > ERROR_MAX)
        ? message.substring(0, ERROR_MAX)
        : message
    );
    // Contact_Id__c is a Contact lookup -- only legal to set for Contact ids.
    //if (sObjectName == 'Contact') row.Contact_Id__c = sfId;
    buffer.add(row);
  }

  /**
   * Call once, after every callout in the transaction has completed.
   *
   * Partial-success and exception-safe on purpose. This is a DIAGNOSTIC sink:
   * failing to record a failure must never escalate into failing the work that
   * was reporting it. A bare insert would let one bad row -- an over-length
   * value, a portal string the restricted picklist does not know -- roll back
   * the entire calling transaction, which for the inbound batch means losing
   * the cursor advance too and replaying the same window forever.
   */
  public static void flush() {
    if (buffer.isEmpty())
      return;
    List<PortalSyncDeadLetter__c> rows = buffer;
    // Cleared BEFORE the insert, so a throw cannot leave the buffer in place
    // to be re-inserted by the next flush in the same transaction.
    buffer = new List<PortalSyncDeadLetter__c>();
    try {
      Database.insert(rows, false);
    } catch (Exception e) {
      // Nothing useful left to do -- the audit trail is the thing that
      // failed. Keep it in the debug log and let the caller finish.
      System.debug(
        LoggingLevel.ERROR,
        'PortalSyncDeadLetter.flush() could not write ' +
          rows.size() +
          ' row(s): ' +
          e.getMessage()
      );
    }
  }

  /** Rows buffered but not yet flushed -- lets a test assert on what WOULD be
   *  written without depending on DML having happened yet. */
  @TestVisible
  private static List<PortalSyncDeadLetter__c> pending() {
    return buffer;
  }
}
