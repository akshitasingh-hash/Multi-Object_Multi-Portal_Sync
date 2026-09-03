/**
 * Account's inbound poll. Exists only to give PortalSyncScheduler and
 * PortalInboundScheduler a distinct AsyncApexJob.ApexClass.Name to guard on --
 * AsyncApexJob cannot expose constructor arguments, so the object identity has
 * to live in the class name. All behaviour is in PortalInboundBatch.
 *
 * Named in Portal_Sync_Object__mdt.Inbound_Batch_Class__c.
 */
public with sharing class AccountInboundBatch extends PortalInboundBatch {
  public AccountInboundBatch() {
    super('Account');
  }
}
