/**
 * Opportunity's inbound poll. See AccountInboundBatch for why a distinct class
 * name is required. All behaviour is in PortalInboundBatch.
 *
 * Named in Portal_Sync_Object__mdt.Inbound_Batch_Class__c.
 */
public with sharing class OpportunityInboundBatch extends PortalInboundBatch {
  public OpportunityInboundBatch() {
    super('Opportunity');
  }
}
