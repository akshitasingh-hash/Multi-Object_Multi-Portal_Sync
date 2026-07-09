/**
 * Asset's outbox drainer. All the logic lives in the generic PortalOutboxBatch;
 * this thin subclass exists so the object has its own ApexClass.Name for the
 * scheduler's per-object overlap guard (see PortalOutboxBatch).
 */
public with sharing class AssetOutboxBatch extends PortalOutboxBatch {
    public AssetOutboxBatch() {
        super('Asset');
    }
}
