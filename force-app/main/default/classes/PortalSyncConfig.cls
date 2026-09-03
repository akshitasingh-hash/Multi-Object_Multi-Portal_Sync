/**
 * Environment wiring + outbox constants for the generic portal sync.
 *
 * Two dimensions drive everything:
 *   - PORTALS (shared across objects): a portal is a HubSpot account fronted by a
 *     Named Credential. The same portal hosts contacts, companies, etc., so the
 *     portal maps below stay object-agnostic.
 *   - OBJECTS (Portal_Sync_Object__mdt): one row per synced SObject naming its
 *     HubSpot path, its sf-id property, and the API names of its portal + HS_*
 *     status fields. Admins add an object row (plus its mapping rows) with no
 *     deploy; the only per-object Apex is a thin trigger + one-line batch subclass.
 */
public with sharing class PortalSyncConfig {
  // Portal value -> Named Credential. Only ENABLED portals belong here; a
  // portal removed from this map is fully disabled (no callouts ever reach it,
  // and it is ignored when parsing a record's portal field). Shared by every
  // synced object. Re-enable by uncommenting.
  public static final Map<String, String> PORTAL_TO_NAMED_CREDENTIAL = new Map<String, String>{
    'Carl Software' => 'HubSpot_Carl',
    'TriBU' => 'HubSpot_TriBU',
    'Berger-Levrault Spain' => 'HubSpot_Spain'
  };

  // Portal value -> the HubSpot_Field_Mapping__mdt checkbox that gates whether a
  // field syncs to THAT portal. Every enabled portal in PORTAL_TO_NAMED_CREDENTIAL
  // needs an entry here; a portal missing from this map syncs no fields at all.
  private static final Map<String, String> PORTAL_TO_SYNC_FIELD = new Map<String, String>{
    'Carl Software' => 'Syncs_To_CARL__c',
    'TriBU' => 'Syncs_To_TriBU__c',
    'Berger-Levrault Spain' => 'Syncs_To_Spain__c'
  };

  // Portal value -> the Portal_Sync_Association__mdt Number field holding THAT
  // portal's HubSpot association type id. Ids for custom objects and for
  // USER_DEFINED labels are generated inside each portal, so the same logical
  // link (e.g. Asset -> Account) carries a different type id in TriBU, CARL and
  // Spain. A portal whose override is blank falls back to the shared
  // Association_Type_Id__c -- correct for HUBSPOT_DEFINED ids, which are stable
  // across portals. A portal missing from this map can only use the fallback.
  private static final Map<String, String> PORTAL_TO_ASSOC_TYPE_FIELD = new Map<String, String>{
    'Carl Software' => 'Association_Type_Id_CARL__c',
    'TriBU' => 'Association_Type_Id_TriBU__c',
    'Berger-Levrault Spain' => 'Association_Type_Id_Spain__c'
  };

  // Portal value -> the Portal_Sync_Value_Map__mdt Text field holding THAT
  // portal's translated value. Same shape as the association-type map above and
  // for the same reason: a HubSpot picklist option's INTERNAL VALUE is defined
  // per portal, so "Renewal Business" may be renewal_business in TriBU and
  // renewal in CARL. A portal whose override is blank falls back to the shared
  // HubSpot_Value__c -- correct whenever the portals agree, which is the norm.
  private static final Map<String, String> PORTAL_TO_VALUE_FIELD = new Map<String, String>{
    'Carl Software' => 'HubSpot_Value_CARL__c',
    'TriBU' => 'HubSpot_Value_TriBU__c',
    'Berger-Levrault Spain' => 'HubSpot_Value_Spain__c'
  };

  // Portal value -> the HubSpot_Field_Mapping__mdt picklist holding THAT portal's
  // direction override. Same shared-default-plus-override shape as the two maps
  // above, and for a directly analogous reason: ownership of a field is a
  // per-portal fact. A field can be HubSpot-owned in TriBU while staying
  // Salesforce-owned in Spain, which is how "TriBU owns phone, Spain is
  // read-only for it" is expressed in config rather than in code. A portal
  // missing from this map can only use the shared Direction__c.
  private static final Map<String, String> PORTAL_TO_DIRECTION_FIELD = new Map<String, String>{
    'Carl Software' => 'Direction_CARL__c',
    'TriBU' => 'Direction_TriBU__c',
    'Berger-Levrault Spain' => 'Direction_Spain__c'
  };

  // Sync direction for one (field, portal). BLANK RESOLVES TO SF_TO_HS, so every
  // mapping row written before inbound existed keeps its original behaviour with
  // no data edit -- the whole direction feature is a no-op until a row is changed.
  //
  // The config fields are RESTRICTED PICKLISTS, so the schema is the primary
  // guard -- an invalid direction cannot be saved. (Custom Metadata Types
  // reject a *global* value set, so each field carries its own inline one;
  // keep the three values identical across all four fields.)
  //
  // normalizeDirection below is the second line of defence, not the first. It
  // still earns its place: it absorbs case and whitespace, and it fails CLOSED
  // for anything unrecognised -- which is what protects data that predates the
  // picklist, or a field someone later unrestricts. A typo must never be able
  // to hand HubSpot ownership of a field by accident.
  public static final String DIR_SF_TO_HS = 'SF_to_HS';
  public static final String DIR_HS_TO_SF = 'HS_to_SF';
  public static final String DIR_BIDIRECTIONAL = 'Bidirectional';

  /** A configured direction value -> one of the three constants, matched
   *  case-insensitively and whitespace-tolerantly. Returns null for blank (the
   *  caller then applies the SF_to_HS default) and for anything unrecognised,
   *  which FieldMap records so it can be reported rather than silently ignored. */
  @TestVisible
  private static String normalizeDirection(String raw) {
    if (String.isBlank(raw))
      return null;
    String v = raw.trim();
    if (v.equalsIgnoreCase(DIR_SF_TO_HS))
      return DIR_SF_TO_HS;
    if (v.equalsIgnoreCase(DIR_HS_TO_SF))
      return DIR_HS_TO_SF;
    if (v.equalsIgnoreCase(DIR_BIDIRECTIONAL))
      return DIR_BIDIRECTIONAL;
    return null;
  }

  // Inbound cursor outcomes (HS_Inbound_Cursor__c.Last_Status__c).
  public static final String INBOUND_OK = 'OK';
  public static final String INBOUND_FAILED = 'Failed';
  public static final String INBOUND_DEFERRED = 'Deferred';

  // Inbound defaults, applied when the Portal_Sync_Object__mdt row leaves the
  // corresponding field blank. Defaulted in Apex rather than in metadata so an
  // existing object row needs no edit to become pollable.
  public static final String DEFAULT_MODIFIED_PROPERTY = 'hs_lastmodifieddate';
  public static final Integer DEFAULT_OVERLAP_SECONDS = 300;
  public static final Integer DEFAULT_SKEW_SECONDS = 120;
  public static final Integer DEFAULT_MAX_PAGES = 20;
  public static final Integer DEFAULT_LOOKBACK_DAYS = 1;

  // Outbox status values (per-object status field and tombstone Status__c).
  public static final String STATUS_PENDING = 'Pending';
  public static final String STATUS_PROCESSING = 'Processing';
  public static final String STATUS_SYNCED = 'Synced';
  public static final String STATUS_FAILED = 'Failed';

  // Holding state for a record inbound just CREATED, whose Salesforce id has
  // not yet been written back to the HubSpot record it came from. It is
  // deliberately not one of the four values above, so the outbox drain query
  // ("Pending, or Failed under the retry cap") does not pick it up: pushing it
  // would upsert by sf-id property, match nothing, and CREATE A SECOND HubSpot
  // record beside the original. PortalInboundStampBatch flips it to Pending
  // once the write-back is confirmed, and the record then fans out normally.
  //
  // NOTE: this only persists where the object's status field is free-text.
  // HS_Sync_Status__c is Text(40) on Account/Opportunity/Asset but a RESTRICTED
  // picklist on Contact -- so enabling inbound CREATES for Contact also
  // requires adding this value to that picklist. It will fail loudly (a DML
  // error, dead-lettered) rather than silently, which is the right trade.
  public static final String STATUS_AWAITING_WRITEBACK = 'Awaiting_Writeback';

  // Batch scope. The router uses HubSpot's batch endpoints, so callouts scale
  // with the number of enabled portals -- NOT with the record count. Scope
  // tracks HubSpot's 100-records-per-batch sweet spot.
  public static final Integer BATCH_SCOPE = 100;

  // A Failed row is retried until it hits this cap, then left for manual review.
  public static final Integer MAX_RETRIES = 5;

  // ---- Per-object configuration (Portal_Sync_Object__mdt) -----------------

  /** Resolved configuration for one synced SObject. All the object-specific
   *  wiring the generic engine needs: HubSpot endpoint, match key, and the API
   *  names of the object's portal + governance fields (configurable per object,
   *  so different objects may use different field names). */
  public class ObjectConfig {
    public String sObjectName;
    public String hubSpotPath; // /crm/v3/objects/{hubSpotPath}
    public String sfIdProperty; // HubSpot unique property holding the SF id
    public String portalField; // multiselect portal field API name
    public String statusField; // sync status field API name
    public String portalChangedField; // "portal moved" flag field API name
    public String retryCountField; // retry counter field API name
    public String lastSyncField; // last-sync datetime field API name
    public String syncMessageField; // human-readable message field API name
    public String outboxBatchClass; // Apex class the scheduler launches
    public Boolean active;
    public Boolean syncOwner; // resolve Owner by email -> hubspot_owner_id on every portal

    // ---- Inbound (HubSpot -> Salesforce) ----
    // contentChangedField is the provenance stamp: when a MAPPED field last
    // really changed in Salesforce. It exists because the engine's own status
    // DML bumps LastModifiedDate on every record it touches, so LastModifiedDate
    // would make Salesforce win every conflict and inbound would silently never
    // apply anything. Blank falls back to LastModifiedDate with that caveat.
    public String contentChangedField;
    public String inboundBatchClass; // distinct class name -> per-object overlap guard
    public String inboundModifiedProperty; // HubSpot property filtered/sorted on
    public Integer inboundOverlapSeconds; // re-query window absorbing search-index lag
    public Integer inboundSkewSeconds; // tolerance band for the conflict comparison
    public Integer inboundMaxPages; // page cap per (object, portal) per run
    public Integer inboundLookbackDays; // cold-start window when no cursor exists
    public Boolean inboundActive;
    public Boolean inboundCreateUnmatched; // may a blank-sf-id HubSpot record create one?
    public Boolean inboundConfirmBlanks; // re-read via batch/read before applying a clear
    public String inboundRecordType; // RecordType DeveloperName for created records
    public String inboundDefaultOwner; // username owning created records

    /** True when this object is wired for polling: enabled outbound, opted in
     *  to inbound, AND naming a concrete batch class. All three are required --
     *  a blank class name is a deliberate second guard, so an object cannot be
     *  polled by ticking one checkbox alone. */
    public Boolean pollable() {
      return active == true &&
        inboundActive == true &&
        String.isNotBlank(inboundBatchClass);
    }
  }

  // Loaded lazily and cached for the life of the transaction. getAll() does not
  // consume a SOQL query.
  private static Map<String, ObjectConfig> objectConfigsByName;

  private static Map<String, ObjectConfig> objectConfigs() {
    if (objectConfigsByName == null) {
      objectConfigsByName = new Map<String, ObjectConfig>();
      for (
        Portal_Sync_Object__mdt o : Portal_Sync_Object__mdt.getAll().values()
      ) {
        if (String.isBlank(o.SObject_API_Name__c))
          continue;
        ObjectConfig cfg = new ObjectConfig();
        cfg.sObjectName = o.SObject_API_Name__c;
        cfg.hubSpotPath = o.HubSpot_Object_Path__c;
        cfg.sfIdProperty = o.SF_Id_Property__c;
        cfg.portalField = o.Portal_Field__c;
        cfg.statusField = o.Sync_Status_Field__c;
        cfg.portalChangedField = o.Portal_Changed_Field__c;
        cfg.retryCountField = o.Retry_Count_Field__c;
        cfg.lastSyncField = o.Last_Sync_Field__c;
        cfg.syncMessageField = o.Sync_Message_Field__c;
        cfg.outboxBatchClass = o.Outbox_Batch_Class__c;
        cfg.active = (o.Active__c == true);
        cfg.syncOwner = (o.Sync_Owner__c == true);

        cfg.contentChangedField = o.Content_Changed_Field__c;
        cfg.inboundBatchClass = o.Inbound_Batch_Class__c;
        cfg.inboundActive = (o.Inbound_Active__c == true);
        cfg.inboundCreateUnmatched = (o.Inbound_Create_Unmatched__c == true);
        cfg.inboundConfirmBlanks = (o.Inbound_Confirm_Blanks__c == true);
        cfg.inboundRecordType = o.Inbound_Record_Type__c;
        cfg.inboundDefaultOwner = o.Inbound_Default_Owner__c;
        cfg.inboundModifiedProperty = String.isNotBlank(
            o.Inbound_Modified_Property__c
          )
          ? o.Inbound_Modified_Property__c
          : DEFAULT_MODIFIED_PROPERTY;
        cfg.inboundOverlapSeconds = intOr(
          o.Inbound_Overlap_Seconds__c,
          DEFAULT_OVERLAP_SECONDS
        );
        cfg.inboundSkewSeconds = intOr(
          o.Inbound_Skew_Seconds__c,
          DEFAULT_SKEW_SECONDS
        );
        cfg.inboundMaxPages = intOr(o.Inbound_Max_Pages__c, DEFAULT_MAX_PAGES);
        cfg.inboundLookbackDays = intOr(
          o.Inbound_Initial_Lookback_Days__c,
          DEFAULT_LOOKBACK_DAYS
        );

        objectConfigsByName.put(cfg.sObjectName, cfg);
      }
    }
    return objectConfigsByName;
  }

  /** A blank Number on the config row means "use the engine default", so treat
   *  null as absent rather than as zero -- a zero page cap or zero lookback
   *  would silently disable polling instead of configuring it. */
  private static Integer intOr(Decimal raw, Integer fallback) {
    return (raw == null) ? fallback : raw.intValue();
  }

  /** Config for one object (null if the object has no Portal_Sync_Object__mdt row). */
  public static ObjectConfig objectConfig(String sObjectName) {
    return objectConfigs().get(sObjectName);
  }

  /** Every enabled object -- what the scheduler iterates to launch outboxes. */
  public static List<ObjectConfig> activeObjects() {
    List<ObjectConfig> result = new List<ObjectConfig>();
    for (ObjectConfig cfg : objectConfigs().values()) {
      if (cfg.active)
        result.add(cfg);
    }
    return result;
  }

  /** Every object wired for polling -- what the inbound scheduler iterates.
   *  Deliberately narrower than activeObjects(): the two directions are opted
   *  into separately, so enabling outbound never enables inbound. */
  public static List<ObjectConfig> inboundObjects() {
    List<ObjectConfig> result = new List<ObjectConfig>();
    for (ObjectConfig cfg : objectConfigs().values()) {
      if (cfg.pollable())
        result.add(cfg);
    }
    return result;
  }

  // ---- Field mappings (HubSpot_Field_Mapping__mdt), keyed per object -------
  // The field contract is PER OBJECT and PER PORTAL: a field belongs to
  // (object, portal) only when its mapping row is Active__c, names that object
  // in Portal_Sync_Object__c, AND that portal's Syncs_To_* checkbox is checked.
  // All admin-managed so the contract can change without a deploy.
  //
  // Syncs_To_* answers WHETHER a field is in play for a portal; Direction
  // answers WHICH WAY it moves. The two are independent, and Syncs_To_* wins:
  // direction is meaningless for a field the portal does not sync at all.

  /** One resolved mapping row. Carries the per-portal direction rather than a
   *  bare property name, because ownership of a field is a per-portal fact. */
  public class FieldMap {
    public String sObjectName;
    public String sfField;
    public String hubSpotProperty;
    public Boolean inboundClears; // may an empty HubSpot value clear the SF field?
    public String defaultDirection; // Direction__c -- fallback for every portal
    public Map<String, String> directionByPortal = new Map<String, String>();
    public Map<String, Boolean> portalOptIn = new Map<String, Boolean>();
    /** Direction strings on this row that are non-blank but not one of the
     *  three recognised values. Each was treated as SF_to_HS (fail closed);
     *  they are kept so the engine can report a config typo instead of
     *  quietly ignoring it. */
    public List<String> invalidDirections = new List<String>();

    /** Whether SF_Field__c actually exists and is readable on the object.
     *  A row naming a field the org does not have is EXCLUDED from every
     *  field set rather than allowed to break the object -- see
     *  fieldExists(). */
    public Boolean fieldResolves = true;

    public Boolean syncsTo(String portal) {
      return portalOptIn.get(portal) == true;
    }

    /**
     * The direction for ONE portal: that portal's override if it carries one,
     * else the shared default, else SF_to_HS. Null only when the portal does
     * not sync this field at all.
     *
     * Always ask per portal -- never read defaultDirection directly. A blank
     * override must fall THROUGH to the shared value rather than shadow it,
     * the same rule the association type ids and value maps follow.
     */
    public String directionFor(String portal) {
      if (!syncsTo(portal))
        return null;
      String own = directionByPortal.get(portal);
      String resolved = String.isNotBlank(own) ? own : defaultDirection;
      return String.isBlank(resolved) ? DIR_SF_TO_HS : resolved;
    }

    /** Salesforce may write this field into the portal (outbound payload). */
    public Boolean sendsTo(String portal) {
      String d = directionFor(portal);
      return d == DIR_SF_TO_HS || d == DIR_BIDIRECTIONAL;
    }

    /** The portal may write this field into Salesforce (inbound apply). */
    public Boolean receivesFrom(String portal) {
      String d = directionFor(portal);
      return d == DIR_HS_TO_SF || d == DIR_BIDIRECTIONAL;
    }

    /** Both sides may own it, so a conflict needs resolving by timestamp.
     *  Only these fields pay the cost of the outbound read-before-write. */
    public Boolean isBidirectional(String portal) {
      return directionFor(portal) == DIR_BIDIRECTIONAL;
    }
  }

  // object -> its active mapping rows.
  private static Map<String, List<FieldMap>> fieldMapsByObject;

  private static Map<String, List<FieldMap>> fieldMaps() {
    if (fieldMapsByObject == null) {
      fieldMapsByObject = new Map<String, List<FieldMap>>();
      for (HubSpot_Field_Mapping__mdt m : [
        SELECT
          Id,
          Active__c,
          HubSpot_Property__c,
          SF_Field__c,
          Syncs_To_TriBU__c,
          Syncs_To_CARL__c,
          Syncs_To_Spain__c,
          Direction__c,
          Direction_TriBU__c,
          Direction_CARL__c,
          Direction_Spain__c,
          Inbound_Clears__c,
          Portal_Sync_Object__r.SObject_API_Name__c,
          Portal_Sync_Object__r.HubSpot_Object_Path__c
        FROM HubSpot_Field_Mapping__mdt
        WHERE Portal_Sync_Object__r.Active__c = TRUE AND Active__c = TRUE
      ]) {
        if (
          !m.Active__c ||
          String.isBlank(m.Portal_Sync_Object__r.SObject_API_Name__c) ||
          String.isBlank(m.SF_Field__c) ||
          String.isBlank(m.HubSpot_Property__c)
        ) {
          continue;
        }
        FieldMap fm = new FieldMap();
        fm.sObjectName = m.Portal_Sync_Object__r.SObject_API_Name__c;
        fm.sfField = m.SF_Field__c;
        fm.hubSpotProperty = m.HubSpot_Property__c;
        fm.inboundClears = (m.Inbound_Clears__c == true);
        fm.fieldResolves = fieldExists(fm.sObjectName, fm.sfField);
        fm.defaultDirection = normalizeDirection(m.Direction__c);
        if (fm.defaultDirection == null && String.isNotBlank(m.Direction__c)) {
          fm.invalidDirections.add('Direction__c = "' + m.Direction__c + '"');
        }
        for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
          Object opt = m.get(PORTAL_TO_SYNC_FIELD.get(portal));
          fm.portalOptIn.put(portal, opt != null && (Boolean) opt);
          // Only record a real override; a blank one must fall through
          // to defaultDirection, not shadow it with null.
          String dirField = PORTAL_TO_DIRECTION_FIELD.get(portal);
          if (dirField == null)
            continue;
          Object own = m.get(dirField);
          String rawOverride = (own == null) ? null : String.valueOf(own);
          String normalized = normalizeDirection(rawOverride);
          if (normalized != null) {
            fm.directionByPortal.put(portal, normalized);
          } else if (String.isNotBlank(rawOverride)) {
            fm.invalidDirections.add(dirField + ' = "' + rawOverride + '"');
          }
        }
        if (!fieldMapsByObject.containsKey(fm.sObjectName)) {
          fieldMapsByObject.put(fm.sObjectName, new List<FieldMap>());
        }
        fieldMapsByObject.get(fm.sObjectName).add(fm);
      }
    }
    return fieldMapsByObject;
  }

  // object -> the field names it actually has, lowercased. Describe-only, and
  // the platform caches the describe, so this costs no query.
  private static Map<String, Set<String>> fieldNamesByObject = new Map<String, Set<String>>();

  /**
   * Whether a mapping row's SF_Field__c really exists on the object.
   *
   * A row naming a field the org does not have is a config error that would
   * otherwise be catastrophic rather than merely wrong: the field name reaches
   * the outbox SOQL, the reconciliation SOQL and the trigger's change
   * detection, so ONE bad row makes every save and every sync of that object
   * fail. That is far worse than the field simply not syncing. Skipping it
   * follows the engine's existing rule -- refuse the ambiguous case, report it,
   * and keep going.
   *
   * A cross-object path is treated as unresolvable too: the engine reads
   * mapped fields with record.get(), which cannot traverse a relationship, so
   * such a row could never have worked.
   */
  @TestVisible
  private static Boolean fieldExists(String sObjectName, String sfField) {
    if (String.isBlank(sObjectName) || String.isBlank(sfField))
      return false;
    if (sfField.contains('.'))
      return false;
    Set<String> names = fieldNamesByObject.get(sObjectName);
    if (names == null) {
      names = new Set<String>();
      Schema.SObjectType sot = Schema.getGlobalDescribe().get(sObjectName);
      if (sot != null) {
        for (String name : sot.getDescribe().fields.getMap().keySet()) {
          names.add(name.toLowerCase());
        }
      }
      fieldNamesByObject.put(sObjectName, names);
    }
    return names.contains(sfField.toLowerCase());
  }

  /** Active mapping rows for one object that the org can actually satisfy.
   *  Rows naming a missing field are dropped here, once, so no caller has to
   *  remember to guard against them. */
  public static List<FieldMap> fieldMapsFor(String sObjectName) {
    List<FieldMap> rows = fieldMaps().get(sObjectName);
    if (rows == null)
      return new List<FieldMap>();
    List<FieldMap> usable = new List<FieldMap>();
    for (FieldMap fm : rows) {
      if (fm.fieldResolves == true)
        usable.add(fm);
    }
    return usable;
  }

  // SF field -> HubSpot property for a single (object, portal) -- exactly what a
  // callout to `portal` sends. Direction-filtered: an HS_to_SF field is excluded,
  // because pushing a HubSpot-owned value back would overwrite it on every drain
  // and every nightly reconcile.
  public static Map<String, String> fieldMapFor(
    String sObjectName,
    String portal
  ) {
    Map<String, String> result = new Map<String, String>();
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      if (fm.sendsTo(portal))
        result.put(fm.sfField, fm.hubSpotProperty);
    }
    return result;
  }

  // HubSpot property -> SF field for a single (object, portal) -- what an inbound
  // poll of `portal` asks for and is allowed to apply. Keyed by HubSpot property
  // because that is the side the response arrives keyed on. Empty means the
  // portal is skipped entirely, with no callout at all.
  public static Map<String, String> inboundFieldMapFor(
    String sObjectName,
    String portal
  ) {
    Map<String, String> result = new Map<String, String>();
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      if (fm.receivesFrom(portal))
        result.put(fm.hubSpotProperty, fm.sfField);
    }
    return result;
  }

  // The WIDE union: every SF field mapped in any direction to any portal. This
  // is the SOQL select list, and the set the provenance stamp watches -- a
  // Salesforce edit to a HubSpot-owned field must still move the provenance
  // clock even though it must not enqueue an outbound push.
  public static Set<String> mappedSfFields(String sObjectName) {
    Set<String> fields = new Set<String>();
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
        if (fm.syncsTo(portal)) {
          fields.add(fm.sfField);
          break;
        }
      }
    }
    return fields;
  }

  // The NARROW union: only fields Salesforce may actually push somewhere. This
  // is the trigger's stamping set, and the reason inbound cannot loop: a field
  // that is HS_to_SF in every portal it syncs to is absent from this set, so an
  // inbound write to it CANNOT re-stamp Pending. The echo problem is therefore
  // structurally confined to fields that legitimately fan out.
  public static Set<String> outboundSfFields(String sObjectName) {
    Set<String> fields = new Set<String>();
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
        if (fm.sendsTo(portal)) {
          fields.add(fm.sfField);
          break;
        }
      }
    }
    return fields;
  }

  // Every SF field any portal may write inbound -- the extra fields an inbound
  // poll must select so it can diff current values before writing.
  public static Set<String> inboundSfFields(String sObjectName) {
    Set<String> fields = new Set<String>();
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
        if (fm.receivesFrom(portal)) {
          fields.add(fm.sfField);
          break;
        }
      }
    }
    return fields;
  }

  /** Fields whose ownership is shared with ONE portal, so an outbound push must
   *  first check whether HubSpot's copy is newer. Empty for the overwhelmingly
   *  common case, which is what keeps the read-before-write cost at zero until
   *  someone deliberately opts a field into two-way sync. */
  public static Set<String> bidirectionalSfFields(
    String sObjectName,
    String portal
  ) {
    Set<String> fields = new Set<String>();
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      if (fm.isBidirectional(portal))
        fields.add(fm.sfField);
    }
    return fields;
  }

  /** True when ANY portal shares ownership of ANY field on this object -- the
   *  cheap up-front test that lets the router skip the extra read entirely. */
  public static Boolean hasBidirectionalFields(String sObjectName) {
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
        if (fm.isBidirectional(portal))
          return true;
      }
    }
    return false;
  }

  /** Human-readable complaints about unrecognised direction values on this
   *  object's mapping rows. Each was treated as SF_to_HS, so nothing unsafe
   *  happened -- but a typo that silently disables inbound for a field would
   *  otherwise be invisible, and the schema cannot catch it (see
   *  normalizeDirection). The inbound engine reports these once per run. */
  public static List<String> directionConfigWarnings(String sObjectName) {
    List<String> out = new List<String>();
    // Deliberately reads the RAW rows, not fieldMapsFor(): a row dropped for
    // naming a missing field is exactly the one an admin needs told about.
    List<FieldMap> rows = fieldMaps().get(sObjectName);
    if (rows == null)
      return out;
    for (FieldMap fm : rows) {
      if (fm.fieldResolves != true) {
        out.add(
          fm.sfField +
            ' does not exist on ' +
            sObjectName +
            ' (or is a cross-object path) -- the whole mapping row is ignored. ' +
            'Left in place it would break every save and every sync of this object.'
        );
      }
      for (String bad : fm.invalidDirections) {
        out.add(
          fm.sfField +
            ': ' +
            bad +
            ' is not one of SF_to_HS / HS_to_SF / Bidirectional -- treated as SF_to_HS'
        );
      }
    }
    return out;
  }

  /** Whether an empty HubSpot value may clear this Salesforce field. */
  public static Boolean inboundClears(String sObjectName, String sfField) {
    for (FieldMap fm : fieldMapsFor(sObjectName)) {
      if (fm.sfField.equalsIgnoreCase(sfField))
        return fm.inboundClears == true;
    }
    return false;
  }

  public static List<String> allPortalValues() {
    return new List<String>(PORTAL_TO_NAMED_CREDENTIAL.keySet());
  }

  /** Custom Metadata cannot be inserted in a test, so tests seed the cache
   *  directly with fully-built FieldMap rows. */
  @TestVisible
  private static void setFieldMapsForTest(Map<String, List<FieldMap>> maps) {
    fieldMapsByObject = maps;
  }

  /** Builds one mapping row for a test without touching Custom Metadata.
   *  `directions` is portal -> direction; a portal absent from it does not sync
   *  the field at all, which is how tests exercise the Syncs_To_* gate. */
  @TestVisible
  private static FieldMap newFieldMapForTest(
    String sObjectName,
    String sfField,
    String hubSpotProperty,
    String defaultDirection,
    Map<String, String> directions,
    Boolean inboundClears
  ) {
    FieldMap fm = new FieldMap();
    fm.sObjectName = sObjectName;
    fm.sfField = sfField;
    fm.hubSpotProperty = hubSpotProperty;
    fm.defaultDirection = normalizeDirection(defaultDirection);
    fm.inboundClears = inboundClears;
    // Resolved the same way the real loader resolves it, so a seeded row
    // naming a missing field behaves in a test exactly as it would in the org.
    fm.fieldResolves = fieldExists(sObjectName, sfField);
    for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
      Boolean optedIn = directions != null && directions.containsKey(portal);
      fm.portalOptIn.put(portal, optedIn);
      if (optedIn) {
        String normalized = normalizeDirection(directions.get(portal));
        if (normalized != null)
          fm.directionByPortal.put(portal, normalized);
      }
    }
    return fm;
  }

  // ---- Value maps (Portal_Sync_Value_Map__mdt) -----------------------------
  // Field mappings decide WHICH value moves; value maps decide WHAT it looks
  // like on arrival. Needed wherever the two systems disagree on representation
  // -- above all a Salesforce id or picklist landing in a HubSpot picklist,
  // which rejects any value that is not a defined option.
  //
  // Loaded from its OWN lazy cache, deliberately separate from fieldMaps():
  // triggers call mappedSfFields() on every save and must not pay for a query
  // only the callout path needs.
  //
  // Key is object + SF field (both lowercased) -> portal -> (SF value lowercased
  // -> HubSpot value). Lowercasing both sides of the lookup makes the match
  // case-insensitive, so a value map keeps working if a picklist API value is
  // recased in Salesforce.
  private static Map<String, Map<String, Map<String, String>>> valueMapsByField;

  // The reverse (HubSpot -> Salesforce) index, built alongside the forward one.
  // Same shape, but keyed on the lowercased HUBSPOT value:
  // object.field -> portal -> (HubSpot value lowercased -> Salesforce value verbatim).
  private static Map<String, Map<String, Map<String, String>>> reverseValueMapsByField;

  // (object.field, portal, HubSpot value) triples that two different Salesforce
  // values both claim, with no Inbound_Preferred__c row to settle it. Inbound
  // must omit the field and dead-letter rather than pick one.
  private static Set<String> ambiguousReverseKeys;

  /** Collects every Salesforce value competing to be the reverse of one HubSpot
   *  value, so the winner can be chosen only after all rows have been seen.
   *  Holds the parts structurally -- the composite key is an opaque map key and
   *  must never be parsed back apart, since a HubSpot value may contain anything. */
  private class ReverseCandidate {
    String fieldKey;
    String portal;
    String hsValueLower;
    Set<String> candidates = new Set<String>();
    Set<String> preferred = new Set<String>();
    ReverseCandidate(String fieldKey, String portal, String hsValueLower) {
      this.fieldKey = fieldKey;
      this.portal = portal;
      this.hsValueLower = hsValueLower;
    }
  }

  @TestVisible
  private static String valueMapKey(String sObjectName, String sfField) {
    return (sObjectName + '.' + sfField).toLowerCase();
  }

  /** Opaque cache key for one (object.field, portal, HubSpot value) triple. */
  @TestVisible
  private static String reverseKey(
    String fieldKey,
    String portal,
    String hsValue
  ) {
    return fieldKey +
      '|' +
      portal +
      '|' +
      (hsValue == null ? '' : hsValue.trim().toLowerCase());
  }

  private static Map<String, Map<String, Map<String, String>>> valueMaps() {
    if (valueMapsByField == null) {
      valueMapsByField = new Map<String, Map<String, Map<String, String>>>();
      // The owning object is reached through the mapping row, but resolved
      // from getAll() rather than a second relationship hop in the query --
      // one level of traversal is all this needs, and getAll() costs no SOQL.
      Map<String, ObjectConfig> configById = new Map<String, ObjectConfig>();
      for (
        Portal_Sync_Object__mdt o : Portal_Sync_Object__mdt.getAll().values()
      ) {
        ObjectConfig cfg = objectConfig(o.SObject_API_Name__c);
        if (cfg != null)
          configById.put(String.valueOf(o.Id), cfg);
      }
      // Reverse translation is collected in the SAME pass, then resolved
      // below: a HubSpot value can only be reversed once every row that
      // could claim it has been seen.
      reverseValueMapsByField = new Map<String, Map<String, Map<String, String>>>();
      ambiguousReverseKeys = new Set<String>();
      Map<String, ReverseCandidate> reverseCandidates = new Map<String, ReverseCandidate>();

      for (Portal_Sync_Value_Map__mdt v : [
        SELECT
          Salesforce_Value__c,
          HubSpot_Value__c,
          Active__c,
          Inbound_Preferred__c,
          HubSpot_Value_TriBU__c,
          HubSpot_Value_CARL__c,
          HubSpot_Value_Spain__c,
          Field_Mapping__r.SF_Field__c,
          Field_Mapping__r.Active__c,
          Field_Mapping__r.Portal_Sync_Object__c
        FROM Portal_Sync_Value_Map__mdt
        WHERE Active__c = TRUE AND Field_Mapping__r.Active__c = TRUE
      ]) {
        ObjectConfig owner = configById.get(
          String.valueOf(v.Field_Mapping__r.Portal_Sync_Object__c)
        );
        if (
          owner == null ||
          !owner.active ||
          String.isBlank(v.Field_Mapping__r.SF_Field__c) ||
          String.isBlank(v.Salesforce_Value__c)
        ) {
          continue;
        }
        String obj = owner.sObjectName;
        String key = valueMapKey(obj, v.Field_Mapping__r.SF_Field__c);
        if (!valueMapsByField.containsKey(key)) {
          Map<String, Map<String, String>> byPortal = new Map<String, Map<String, String>>();
          for (String portal : PORTAL_TO_VALUE_FIELD.keySet()) {
            byPortal.put(portal, new Map<String, String>());
          }
          valueMapsByField.put(key, byPortal);
        }
        String sfValue = v.Salesforce_Value__c.trim().toLowerCase();
        if (!reverseValueMapsByField.containsKey(key)) {
          Map<String, Map<String, String>> revByPortal = new Map<String, Map<String, String>>();
          for (String portal : PORTAL_TO_VALUE_FIELD.keySet()) {
            revByPortal.put(portal, new Map<String, String>());
          }
          reverseValueMapsByField.put(key, revByPortal);
        }
        for (String portal : PORTAL_TO_VALUE_FIELD.keySet()) {
          String hsValue = portalValueOf(v, portal);
          if (String.isBlank(hsValue))
            continue;
          valueMapsByField.get(key).get(portal).put(sfValue, hsValue);

          // The Salesforce value is kept VERBATIM on the reverse side:
          // it is written back into a picklist, whose API values are
          // case-sensitive. Only the lookup key is lowercased.
          String composite = reverseKey(key, portal, hsValue);
          ReverseCandidate rc = reverseCandidates.get(composite);
          if (rc == null) {
            rc = new ReverseCandidate(
              key,
              portal,
              hsValue.trim().toLowerCase()
            );
            reverseCandidates.put(composite, rc);
          }
          rc.candidates.add(v.Salesforce_Value__c);
          if (v.Inbound_Preferred__c == true) {
            rc.preferred.add(v.Salesforce_Value__c);
          }
        }
      }

      // Resolve the reverse direction. Forward translation is many-to-one,
      // so reversing it is ambiguous whenever two Salesforce values claim
      // one HubSpot value. Ambiguity is REFUSED rather than guessed, for the
      // same reason a portal with no association type id is skipped: writing
      // the wrong record type or picklist value into Salesforce is worse than
      // writing nothing, and it is silent. "First row wins" would also be
      // non-deterministic between runs, since CMDT row order is not defined.
      for (String composite : reverseCandidates.keySet()) {
        ReverseCandidate rc = reverseCandidates.get(composite);
        String winner;
        if (rc.preferred.size() == 1) {
          winner = new List<String>(rc.preferred)[0]; // explicit tie-break
        } else if (rc.preferred.isEmpty() && rc.candidates.size() == 1) {
          winner = new List<String>(rc.candidates)[0]; // unambiguous anyway
        }
        if (winner == null) {
          ambiguousReverseKeys.add(composite);
          continue;
        }
        reverseValueMapsByField.get(rc.fieldKey)
          .get(rc.portal)
          .put(rc.hsValueLower, winner);
      }
    }
    return valueMapsByField;
  }

  /**
   * One row's value for ONE portal: that portal's override if it carries one,
   * else the shared HubSpot_Value__c. Only a NON-BLANK override wins -- a blank
   * one has to fall through to the shared value rather than shadow it, the same
   * rule the association type ids follow.
   */
  @TestVisible
  private static String portalValueOf(
    Portal_Sync_Value_Map__mdt row,
    String portal
  ) {
    String overrideField = PORTAL_TO_VALUE_FIELD.get(portal);
    if (overrideField != null) {
      Object own = row.get(overrideField);
      if (own != null && String.isNotBlank((String) own))
        return (String) own;
    }
    return row.HubSpot_Value__c;
  }

  /** True when ANY translation is configured for this (object, field) -- i.e.
   *  the field's raw Salesforce value must never be sent as-is. Checked before
   *  translateValue so an untranslated value can be reported rather than
   *  silently shipped to a HubSpot picklist that would reject it. */
  public static Boolean hasValueMap(String sObjectName, String sfField) {
    return valueMaps().containsKey(valueMapKey(sObjectName, sfField));
  }

  /**
   * The HubSpot value to send for one Salesforce value in ONE portal, or null
   * when this (object, field, portal) has no row for it. Null is meaningful:
   * the caller must omit the property rather than guess, because an undefined
   * picklist option fails the record in HubSpot.
   */
  public static String translateValue(
    String sObjectName,
    String sfField,
    String portal,
    String rawValue
  ) {
    if (rawValue == null)
      return null;
    Map<String, Map<String, String>> byPortal = valueMaps()
      .get(valueMapKey(sObjectName, sfField));
    if (byPortal == null)
      return null;
    Map<String, String> values = byPortal.get(portal);
    return (values != null) ? values.get(rawValue.trim().toLowerCase()) : null;
  }

  /** Custom Metadata cannot be inserted in a test, so tests seed the cache
   *  directly: key -> portal -> (SF value lowercased -> HubSpot value). */
  @TestVisible
  private static void setValueMapsForTest(
    Map<String, Map<String, Map<String, String>>> maps
  ) {
    valueMapsByField = maps;
  }

  // ---- Reverse value translation (HubSpot -> Salesforce) -------------------

  /** The reverse index, sharing the forward map's lazy load. Tolerates a test
   *  seeding only one of the two caches, and a config with no value maps at all. */
  private static Map<String, Map<String, Map<String, String>>> reverseValueMaps() {
    // Already populated -- either by the shared load or by a test seeding it
    // directly. Checked BEFORE calling valueMaps(), because that load rebuilds
    // this index and would overwrite a seeded one.
    if (reverseValueMapsByField != null) {
      if (ambiguousReverseKeys == null)
        ambiguousReverseKeys = new Set<String>();
      return reverseValueMapsByField;
    }
    valueMaps(); // reverse index is built by the same lazy load
    if (reverseValueMapsByField == null) {
      reverseValueMapsByField = new Map<String, Map<String, Map<String, String>>>();
    }
    if (ambiguousReverseKeys == null)
      ambiguousReverseKeys = new Set<String>();
    return reverseValueMapsByField;
  }

  /** True when this (object, field) has any reverse translation configured, so
   *  an incoming raw HubSpot value must never be written straight through. The
   *  forward and reverse directions are configured by the SAME rows, so this
   *  mirrors hasValueMap. */
  public static Boolean hasReverseValueMap(String sObjectName, String sfField) {
    return reverseValueMaps().containsKey(valueMapKey(sObjectName, sfField));
  }

  /** True when two Salesforce values both claim this HubSpot value and no
   *  Inbound_Preferred__c row settles it. The caller must omit the field and
   *  dead-letter INBOUND_VALUE_MAP_AMBIGUOUS -- never guess, because the guess
   *  would be silent AND non-deterministic between runs. */
  public static Boolean isReverseAmbiguous(
    String sObjectName,
    String sfField,
    String portal,
    String hsValue
  ) {
    reverseValueMaps();
    return ambiguousReverseKeys.contains(
      reverseKey(valueMapKey(sObjectName, sfField), portal, hsValue)
    );
  }

  /**
   * The Salesforce value one HubSpot value becomes in ONE portal, or null when
   * this (object, field, portal) has no row for it -- or has an unresolved
   * collision. Null is meaningful in exactly the way translateValue's is: the
   * caller must omit the field rather than write a raw HubSpot internal value
   * (typically a GUID) into a Salesforce picklist.
   */
  public static String reverseTranslateValue(
    String sObjectName,
    String sfField,
    String portal,
    String hsValue
  ) {
    if (hsValue == null)
      return null;
    Map<String, Map<String, String>> byPortal = reverseValueMaps()
      .get(valueMapKey(sObjectName, sfField));
    if (byPortal == null)
      return null;
    Map<String, String> values = byPortal.get(portal);
    return (values != null) ? values.get(hsValue.trim().toLowerCase()) : null;
  }

  /** Tests seed the reverse cache directly, alongside the forward one. */
  @TestVisible
  private static void setReverseValueMapsForTest(
    Map<String, Map<String, Map<String, String>>> maps,
    Set<String> ambiguous
  ) {
    reverseValueMapsByField = maps;
    ambiguousReverseKeys = (ambiguous != null) ? ambiguous : new Set<String>();
  }

  // ---- Associations (Portal_Sync_Association__mdt) -------------------------
  // HubSpot associations LINK two already-synced records (by their HubSpot ids),
  // rather than sync field values. Each row names a From object, a To object,
  // how the related record's SF id is found (a Lookup field or a Junction
  // object), the HubSpot association type to assert, and the portals it applies
  // to. Driven by the From object's outbox + reconciliation passes.

  /** Resolved configuration for one association type. Carries both objects'
   *  HubSpot path + sf-id property so the router can resolve either side. */
  public class AssociationConfig {
    public String fromObject;
    public String toObject;
    public String fromHubSpotPath;
    public String toHubSpotPath;
    public String fromSfIdProperty;
    public String toSfIdProperty;
    public String sourceType; // 'Lookup' | 'Junction'
    public String relationshipField; // Lookup: FK field on the From record
    public String junctionObject; // Junction: linking SObject API name
    public String junctionFromField; // Junction: FK -> From record id
    public String junctionToField; // Junction: FK -> To record id
    public String associationCategory; // HUBSPOT_DEFINED | USER_DEFINED
    public Integer defaultTypeId; // Association_Type_Id__c -- fallback for every portal
    public Map<String, Integer> typeIdByPortal = new Map<String, Integer>(); // per-portal overrides
    public Map<String, Boolean> portalOptIn = new Map<String, Boolean>();
    public Boolean active;
    /** Create-only: never archive a link Salesforce does not relate. Needed
     *  wherever Salesforce does not hold the whole truth about the
     *  relationship -- see PortalAssociationRouter. */
    public Boolean suppressRemovals;

    public Boolean isJunction() {
      return 'Junction'.equalsIgnoreCase(sourceType);
    }
    public Boolean syncsTo(String portal) {
      return portalOptIn.get(portal) == true;
    }

    /**
     * The association type id to assert in ONE portal: that portal's override
     * if set, else the shared default. Always ask per portal -- never read
     * defaultTypeId directly -- because custom-object ids differ per portal.
     *
     * Null when neither is configured. The router must then skip the portal
     * rather than guess: a null type id matches EVERY existing association
     * type on read, which would let the diff archive links this row does not
     * own (and HubSpot rejects a create with no type id anyway).
     */
    public Integer typeIdFor(String portal) {
      Integer own = typeIdByPortal.get(portal);
      return (own != null) ? own : defaultTypeId;
    }
  }

  /** A HubSpot association type id is a positive integer, so 0 -- the "not
   *  looked up yet" placeholder in seeded rows -- reads the same as blank. */
  private static Integer assocTypeId(Object raw) {
    if (raw == null)
      return null;
    Decimal value = (Decimal) raw;
    return (value <= 0) ? null : value.intValue();
  }

  // Loaded lazily and cached for the transaction. from-object name -> its rows.
  private static Map<String, List<AssociationConfig>> associationsByFrom;

  private static Map<String, List<AssociationConfig>> associationConfigs() {
    if (associationsByFrom == null) {
      associationsByFrom = new Map<String, List<AssociationConfig>>();
      for (Portal_Sync_Association__mdt a : [
        SELECT
          Source_Type__c,
          Relationship_Field__c,
          Junction_Object__c,
          Junction_From_Field__c,
          Junction_To_Field__c,
          Association_Category__c,
          Association_Type_Id__c,
          Active__c,
          Suppress_Removals__c,
          Association_Type_Id_TriBU__c,
          Association_Type_Id_CARL__c,
          Association_Type_Id_Spain__c,
          Syncs_To_TriBU__c,
          Syncs_To_CARL__c,
          Syncs_To_Spain__c,
          From_Object__r.SObject_API_Name__c,
          From_Object__r.HubSpot_Object_Path__c,
          From_Object__r.SF_Id_Property__c,
          From_Object__r.Active__c,
          To_Object__r.SObject_API_Name__c,
          To_Object__r.HubSpot_Object_Path__c,
          To_Object__r.SF_Id_Property__c,
          To_Object__r.Active__c
        FROM Portal_Sync_Association__mdt
        WHERE
          Active__c = TRUE
          AND From_Object__r.Active__c = TRUE
          AND To_Object__r.Active__c = TRUE
      ]) {
        if (
          String.isBlank(a.From_Object__r.SObject_API_Name__c) ||
          String.isBlank(a.To_Object__r.SObject_API_Name__c)
        ) {
          continue;
        }
        AssociationConfig cfg = new AssociationConfig();
        cfg.fromObject = a.From_Object__r.SObject_API_Name__c;
        cfg.toObject = a.To_Object__r.SObject_API_Name__c;
        cfg.fromHubSpotPath = a.From_Object__r.HubSpot_Object_Path__c;
        cfg.toHubSpotPath = a.To_Object__r.HubSpot_Object_Path__c;
        cfg.fromSfIdProperty = a.From_Object__r.SF_Id_Property__c;
        cfg.toSfIdProperty = a.To_Object__r.SF_Id_Property__c;
        cfg.sourceType = a.Source_Type__c;
        cfg.relationshipField = a.Relationship_Field__c;
        cfg.junctionObject = a.Junction_Object__c;
        cfg.junctionFromField = a.Junction_From_Field__c;
        cfg.junctionToField = a.Junction_To_Field__c;
        cfg.associationCategory = String.isBlank(a.Association_Category__c)
          ? 'HUBSPOT_DEFINED'
          : a.Association_Category__c;
        cfg.defaultTypeId = assocTypeId(a.Association_Type_Id__c);
        cfg.active = (a.Active__c == true);
        cfg.suppressRemovals = (a.Suppress_Removals__c == true);
        for (String portal : PORTAL_TO_SYNC_FIELD.keySet()) {
          Object opt = a.get(PORTAL_TO_SYNC_FIELD.get(portal));
          cfg.portalOptIn.put(portal, opt != null && (Boolean) opt);
          // Only record a real override; a blank one must fall through
          // to defaultTypeId, not shadow it with null.
          String typeIdField = PORTAL_TO_ASSOC_TYPE_FIELD.get(portal);
          if (typeIdField != null) {
            Integer own = assocTypeId(a.get(typeIdField));
            if (own != null)
              cfg.typeIdByPortal.put(portal, own);
          }
        }
        if (!associationsByFrom.containsKey(cfg.fromObject)) {
          associationsByFrom.put(cfg.fromObject, new List<AssociationConfig>());
        }
        associationsByFrom.get(cfg.fromObject).add(cfg);
      }
    }
    return associationsByFrom;
  }

  /** Active associations owned by (driven from) one object. Empty when none. */
  public static List<AssociationConfig> associationsFrom(String sObjectName) {
    List<AssociationConfig> rows = associationConfigs().get(sObjectName);
    return (rows != null) ? rows : new List<AssociationConfig>();
  }

  /** Lookup-source FK fields the From object's outbox/reconciliation SOQL must
   *  select so the router can read the related record id (Junction sources need
   *  no extra field -- they are resolved by a separate query). */
  public static Set<String> associationSourceFields(String sObjectName) {
    Set<String> fields = new Set<String>();
    for (AssociationConfig a : associationsFrom(sObjectName)) {
      if (!a.isJunction() && String.isNotBlank(a.relationshipField)) {
        fields.add(a.relationshipField);
      }
    }
    return fields;
  }

  /**
   * The portal field is a MULTISELECT picklist, so its value arrives as a
   * semicolon-delimited string (e.g. "TriBU;CARL"). Split it and keep only the
   * portals that are currently enabled (present in PORTAL_TO_NAMED_CREDENTIAL);
   * unknown or disabled selections are dropped. Returns an empty set when the
   * record belongs to no enabled portal.
   */
  public static Set<String> selectedPortals(SObject record, ObjectConfig cfg) {
    Set<String> result = new Set<String>();
    String raw = (String) record.get(cfg.portalField);
    if (String.isBlank(raw))
      return result;
    for (String value : raw.split(';')) {
      String portal = value.trim();
      if (PORTAL_TO_NAMED_CREDENTIAL.containsKey(portal)) {
        result.add(portal);
      }
    }
    return result;
  }
}
