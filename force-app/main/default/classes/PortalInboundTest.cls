/**
 * Coverage for the inbound (HubSpot -> Salesforce) direction.
 *
 * Split from PortalSyncTest deliberately: inbound is a second direction rather
 * than another case of the first, and most of its risk lives in a pure decision
 * function that is best tested synchronously.
 *
 * Two styles are used, for a concrete reason. Batch execution resets statics, so
 * a batch cannot see a seeded config cache -- anything driven by seeded metadata
 * must be exercised by calling PortalInboundMapper.decide directly, with a
 * hand-built ObjectConfig. The end-to-end batch tests instead lean on the real
 * shipped Custom Metadata (the Account Description mapping, which is HS_to_SF).
 */
@isTest
private class PortalInboundTest {
  private static final String TRIBU = 'TriBU';
  private static final String SPAIN = 'Berger-Levrault Spain';
  private static final String CARL = 'Carl Software';

  // ---- Helpers ------------------------------------------------------------

  /** An Account config wired the way the shipped metadata wires it. */
  private static PortalSyncConfig.ObjectConfig accountConfig() {
    PortalSyncConfig.ObjectConfig cfg = new PortalSyncConfig.ObjectConfig();
    cfg.sObjectName = 'Account';
    cfg.hubSpotPath = 'companies';
    cfg.sfIdProperty = 'salesforceaccountid_bl';
    cfg.portalField = 'Portal__c';
    cfg.statusField = 'HS_Sync_Status__c';
    cfg.portalChangedField = 'HS_Portal_Changed__c';
    cfg.retryCountField = 'HS_Retry_Count__c';
    cfg.lastSyncField = 'HS_Last_Sync__c';
    cfg.syncMessageField = 'HS_Sync_Message__c';
    cfg.outboxBatchClass = 'AccountOutboxBatch';
    cfg.active = true;
    cfg.syncOwner = false;
    cfg.contentChangedField = 'HS_Content_Changed__c';
    cfg.inboundBatchClass = 'AccountInboundBatch';
    cfg.inboundModifiedProperty = 'hs_lastmodifieddate';
    cfg.inboundOverlapSeconds = 300;
    cfg.inboundSkewSeconds = 120;
    cfg.inboundMaxPages = 20;
    cfg.inboundLookbackDays = 1;
    cfg.inboundActive = true;
    cfg.inboundCreateUnmatched = false;
    cfg.inboundConfirmBlanks = false;
    return cfg;
  }

  /** Seed the field-map cache with one row per (field -> property, directions). */
  private static void seedFieldMaps(List<PortalSyncConfig.FieldMap> rows) {
    PortalSyncConfig.setFieldMapsForTest(
      new Map<String, List<PortalSyncConfig.FieldMap>>{ 'Account' => rows }
    );
  }

  private static PortalSyncConfig.FieldMap mapping(
    String sfField,
    String hsProperty,
    String direction,
    Boolean clears
  ) {
    return PortalSyncConfig.newFieldMapForTest(
      'Account',
      sfField,
      hsProperty,
      direction,
      new Map<String, String>{ TRIBU => null, SPAIN => null, CARL => null },
      clears
    );
  }

  /** One search-style result row. Properties passed are PRESENT; anything
   *  omitted is genuinely absent, which is the distinction under test. */
  private static Map<String, Object> row(
    String hsId,
    Map<String, Object> props
  ) {
    return new Map<String, Object>{ 'id' => hsId, 'properties' => props };
  }

  private static Account insertAccount(String portal, String status) {
    Account a = new Account(Name = 'Acme', Portal__c = portal);
    insert a;
    a.HS_Sync_Status__c = status;
    update a;
    return a;
  }

  /** Re-read an account with everything the mapper needs. */
  private static Map<Id, SObject> reread(Id accountId) {
    return new Map<Id, SObject>(
      [
        SELECT
          Id,
          Name,
          Phone,
          Description,
          Portal__c,
          HS_Sync_Status__c,
          HS_Content_Changed__c,
          CreatedDate,
          LastModifiedDate
        FROM Account
        WHERE Id = :accountId
      ]
    );
  }

  // ---- Direction config ---------------------------------------------------

  @isTest
  static void blankDirectionKeepsAFieldOutboundOnly() {
    // The whole feature has to be a no-op for every mapping row written before
    // inbound existed, or deploying it would silently change live behaviour.
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Phone', 'phone', null, true)
      }
    );
    System.assertEquals(
      PortalSyncConfig.DIR_SF_TO_HS,
      PortalSyncConfig.fieldMapsFor('Account')[0].directionFor(TRIBU),
      'a blank direction must resolve to SF_to_HS'
    );
    System.assert(
      PortalSyncConfig.fieldMapFor('Account', TRIBU).containsKey('Phone'),
      'it still goes out'
    );
    System.assert(
      PortalSyncConfig.inboundFieldMapFor('Account', TRIBU).isEmpty(),
      'and inbound must not see it at all'
    );
  }

  @isTest
  static void perPortalDirectionOverridesTheSharedDefault() {
    // The point of per-portal direction: "TriBU owns phone, Spain is read-only
    // for it" expressed purely in config.
    PortalSyncConfig.FieldMap fm = PortalSyncConfig.newFieldMapForTest(
      'Account',
      'Phone',
      'phone',
      PortalSyncConfig.DIR_SF_TO_HS,
      new Map<String, String>{
        TRIBU => PortalSyncConfig.DIR_HS_TO_SF,
        SPAIN => null,
        CARL => null
      },
      true
    );
    seedFieldMaps(new List<PortalSyncConfig.FieldMap>{ fm });

    System.assertEquals(
      PortalSyncConfig.DIR_HS_TO_SF,
      fm.directionFor(TRIBU),
      'the override wins where it is set'
    );
    System.assertEquals(
      PortalSyncConfig.DIR_SF_TO_HS,
      fm.directionFor(SPAIN),
      'a blank override falls through to the shared value, it must not shadow it'
    );
    System.assert(
      PortalSyncConfig.inboundFieldMapFor('Account', TRIBU)
        .containsKey('phone'),
      'TriBU may write it inbound'
    );
    System.assert(
      PortalSyncConfig.inboundFieldMapFor('Account', SPAIN).isEmpty(),
      'Spain may not'
    );
    System.assert(
      !PortalSyncConfig.fieldMapFor('Account', TRIBU).containsKey('Phone'),
      'and Salesforce must stop pushing a field TriBU owns, or it would overwrite it every drain'
    );
  }

  @isTest
  static void hubSpotOwnedFieldLeavesTheTriggersWatchedSet() {
    // THE structural echo guard. A field HubSpot owns everywhere is absent from
    // outboundSfFields, so an inbound write to it cannot re-stamp Pending and
    // cannot bounce back out. Nothing else in the design prevents that loop.
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        ),
        mapping('Phone', 'phone', PortalSyncConfig.DIR_SF_TO_HS, true)
      }
    );
    Set<String> watched = PortalSyncConfig.outboundSfFields('Account');
    System.assert(
      !watched.contains('Description'),
      'a HubSpot-owned field must not be watched for outbound stamping'
    );
    System.assert(watched.contains('Phone'), 'a Salesforce-owned one must be');
    System.assert(
      PortalSyncConfig.mappedSfFields('Account').contains('Description'),
      'but it stays in the WIDE set, so a Salesforce edit still moves the provenance clock'
    );
  }

  @isTest
  static void anUnrecognisedDirectionFailsClosedAndIsReported() {
    // Custom Metadata Types cannot enforce a picklist, so a typo is possible and
    // must never be able to hand HubSpot ownership by accident.
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Phone', 'phone', 'inbound-ish', true)
      }
    );
    System.assertEquals(
      PortalSyncConfig.DIR_SF_TO_HS,
      PortalSyncConfig.fieldMapsFor('Account')[0].directionFor(TRIBU),
      'an unrecognised direction must degrade to outbound-only'
    );
    System.assert(
      PortalSyncConfig.inboundFieldMapFor('Account', TRIBU).isEmpty(),
      'and grant nothing inbound'
    );
  }

  @isTest
  static void syncsToFalseMakesDirectionIrrelevant() {
    PortalSyncConfig.FieldMap fm = PortalSyncConfig.newFieldMapForTest(
      'Account',
      'Phone',
      'phone',
      PortalSyncConfig.DIR_BIDIRECTIONAL,
      new Map<String, String>{ TRIBU => PortalSyncConfig.DIR_BIDIRECTIONAL },
      true
    );
    seedFieldMaps(new List<PortalSyncConfig.FieldMap>{ fm });
    System.assertEquals(
      null,
      fm.directionFor(SPAIN),
      'a portal that does not sync the field has no direction for it'
    );
    System.assert(!fm.sendsTo(SPAIN) && !fm.receivesFrom(SPAIN));
    System.assert(
      PortalSyncConfig.hasBidirectionalFields('Account'),
      'TriBU still shares ownership'
    );
    System.assert(
      PortalSyncConfig.bidirectionalSfFields('Account', SPAIN).isEmpty(),
      'but Spain shares nothing, so it pays no comparison cost'
    );
  }

  // ---- Reverse value translation ------------------------------------------

  @isTest
  static void reverseTranslationRefusesAnAmbiguousValue() {
    // Forward translation is many-to-one, so reversing it can be ambiguous.
    // Guessing would be silent AND non-deterministic between runs, since CMDT
    // row order is undefined -- so ambiguity is refused outright.
    PortalSyncConfig.setReverseValueMapsForTest(
      new Map<String, Map<String, Map<String, String>>>{
        'account.type' => new Map<String, Map<String, String>>{
          TRIBU => new Map<String, String>{ 'partner' => 'Partner' }
        }
      },
      new Set<String>{ 'account.type|' + TRIBU + '|shared' }
    );
    System.assertEquals(
      'Partner',
      PortalSyncConfig.reverseTranslateValue(
        'Account',
        'Type',
        TRIBU,
        'PARTNER'
      ),
      'lookup is case-insensitive on the HubSpot value'
    );
    System.assert(
      PortalSyncConfig.isReverseAmbiguous('Account', 'Type', TRIBU, 'shared'),
      'a contested value must be reported ambiguous'
    );
    System.assertEquals(
      null,
      PortalSyncConfig.reverseTranslateValue(
        'Account',
        'Type',
        TRIBU,
        'unknown'
      ),
      'and an unmapped value resolves to null so the caller omits the field'
    );
  }

  // ---- The loop terminator ------------------------------------------------

  @isTest
  static void nothingIsWrittenWhenTheValueAlreadyMatches() {
    // This is what makes the engine's own outbound echo harmless: the poll
    // proposes the value Salesforce already has, so there is no DML, hence no
    // Pending stamp, hence no push, hence no new HubSpot timestamp.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'Same';
    update a;

    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        )
      }
    );

    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'Same',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(
              System.now().addHours(1).getTime()
            )
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );

    System.assertEquals(
      0,
      d.recordsApplied(),
      'an unchanged value must produce no DML at all'
    );
    System.assertEquals(
      1,
      d.recordsSeen,
      'though the record was still examined'
    );
  }

  @isTest
  static void aNumericScaleDifferenceIsNotAChange() {
    // String.valueOf(1000.50) is '1000.50' but HubSpot returns '1000.5'. Compared
    // as text this rewrites the field on every poll -- which re-stamps Pending,
    // re-pushes, and bumps the HubSpot timestamp: a real infinite loop.
    System.assert(
      PortalInboundMapper.valuesEqual(1000.50, Decimal.valueOf('1000.5')),
      'numbers must compare numerically, ignoring scale'
    );
    System.assert(
      !PortalInboundMapper.valuesEqual('abc', 'ABC'),
      'strings must compare case-sensitively -- a case-only edit in HubSpot is a real edit'
    );
    System.assert(PortalInboundMapper.valuesEqual(null, null));
    System.assert(!PortalInboundMapper.valuesEqual(null, 'x'));
  }

  // ---- Absent vs present-but-empty ----------------------------------------

  @isTest
  static void anAbsentPropertyIsSkippedButAnEmptyOneClears() {
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'Keep me';
    a.Phone = '123';
    update a;

    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        ),
        mapping('Phone', 'phone', PortalSyncConfig.DIR_HS_TO_SF, true)
      }
    );

    // 'description' is absent from the response entirely; 'phone' is present
    // and empty. Only the second is an instruction.
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'phone' => '',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );

    System.assertEquals(1, d.updates.size());
    Account shell = (Account) d.updates[0];
    System.assertEquals(
      null,
      shell.Phone,
      'a property present but empty is a deliberate clear'
    );
    System.assert(
      !shell.getPopulatedFieldsAsMap().containsKey('Description'),
      'a property absent from the response means we were told nothing, so it must not be touched'
    );
  }

  @isTest
  static void aClearIsRefusedOnARequiredField() {
    // A clear that would fail DML must never reach DML.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Name', 'name', PortalSyncConfig.DIR_HS_TO_SF, true)
      }
    );

    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'name' => '',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(0, d.updates.size(), 'Account.Name cannot be nulled');
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_NULL_REFUSED'
      ],
      'and the refusal is recorded rather than silently dropped'
    );
  }

  @isTest
  static void aClearIsSkippedWhenTheMappingDoesNotConsent() {
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'Keep me';
    update a;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          false
        )
      }
    );

    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => '',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    System.assertEquals(
      0,
      d.updates.size(),
      'Inbound_Clears__c off means blanks are ignored for that field'
    );
  }

  // ---- Identity, deletion, isolation --------------------------------------

  @isTest
  static void aDeletedRecordIsNeverRecreated() {
    // Delete-termination is the property the whole engine rests on. A HubSpot
    // record carrying an sf-id whose Salesforce record is gone is a DELETED
    // record, never a new one -- and this holds with no retention window, which
    // matters because tombstones are deleted once the archive succeeds.
    PortalSyncConfig.ObjectConfig cfg = accountConfig();
    cfg.inboundCreateUnmatched = true; // even with creates ON
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        )
      }
    );

    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    Id deletedId = a.Id;
    delete a;

    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      cfg,
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'resurrect me',
            'salesforceaccountid_bl' => deletedId,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      new Map<Id, SObject>(),
      new Set<String>{ String.valueOf(deletedId) },
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(0, d.creates.size(), 'it must not be recreated');
    System.assertEquals(0, d.updates.size());
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_TOMBSTONED'
      ],
      'and the refusal says the archive is merely pending'
    );
  }

  @isTest
  static void aPollFromTheWrongPortalIsRefused() {
    // Salesforce owns portal membership; a poll must not silently add one.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        )
      }
    );

    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      SPAIN, // polled from a portal the record does not belong to
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'from the wrong portal',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(0, d.updates.size());
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_PORTAL_MISMATCH'
      ]
    );
  }

  @isTest
  static void twoHubSpotRecordsCannotClaimOneSalesforceId() {
    // The sf-id property is free text in HubSpot, so this is reachable. Two
    // update shells for one id would fail the ENTIRE DML, taking the whole page
    // down with them.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        )
      }
    );

    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'first',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        ),
        row(
          '2',
          new Map<String, Object>{
            'description' => 'second',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(
      1,
      d.updates.size(),
      'only the first claimant may produce an update'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_SF_ID_MISMATCH'
      ],
      'the second is refused and reported'
    );
  }

  @isTest
  static void aMalformedSalesforceIdIsRefused() {
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        )
      }
    );
    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'x',
            'salesforceaccountid_bl' => 'not-an-id',
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      new Map<Id, SObject>(),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();
    System.assertEquals(0, d.updates.size());
    System.assertEquals(
      0,
      d.creates.size(),
      'a typo must not become a new record'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_SF_ID_MISMATCH'
      ]
    );
  }

  // ---- Conflict resolution ------------------------------------------------

  @isTest
  static void bidirectionalFieldsFollowNewestModifiedWins() {
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'salesforce value';
    update a;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_BIDIRECTIONAL,
          true
        )
      }
    );
    Map<Id, SObject> existing = reread(a.Id);

    // HubSpot is clearly newer -> it wins.
    PortalInboundMapper.Decision newer = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'hubspot value',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(
              System.now().addDays(1).getTime()
            )
          }
        )
      },
      null,
      existing,
      new Set<String>(),
      new Set<String>(),
      null
    );
    System.assertEquals(1, newer.updates.size(), 'the newer side wins');
    System.assertEquals(
      'hubspot value',
      ((Account) newer.updates[0]).Description
    );

    // HubSpot is older -> Salesforce keeps its value.
    PortalInboundMapper.Decision older = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'stale hubspot value',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(
              System.now().addDays(-1).getTime()
            )
          }
        )
      },
      null,
      existing,
      new Set<String>(),
      new Set<String>(),
      null
    );
    System.assertEquals(
      0,
      older.updates.size(),
      'a stale HubSpot edit must not overwrite a newer Salesforce one'
    );
  }

  @isTest
  static void aChangeInsideTheSkewWindowIsNotTreatedAsNewer() {
    // The band exists for two reasons: the clocks are independent, AND an
    // outbound push legitimately lands in HubSpot minutes after the Salesforce
    // edit that caused it. Without it, every Salesforce change would look like a
    // HubSpot win on the very next poll.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'salesforce value';
    update a;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_BIDIRECTIONAL,
          true
        )
      }
    );

    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(), // 120s tolerance
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'echo of our own push',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(
              System.now().addSeconds(30).getTime()
            )
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    System.assertEquals(
      0,
      d.updates.size(),
      '30s newer is inside the 120s band, so it carries no information'
    );
  }

  @isTest
  static void aHubSpotOwnedFieldNeedsNoTimestampAtAll() {
    // HS_to_SF is ownership by declaration: there is nothing to arbitrate, so a
    // stale-looking timestamp must not stop the write.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'old';
    update a;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          true
        )
      }
    );

    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'description' => 'new',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(
              System.now().addDays(-10).getTime()
            )
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    System.assertEquals(
      1,
      d.updates.size(),
      'HubSpot owns it, so it is written'
    );
    System.assertEquals('new', ((Account) d.updates[0]).Description);
  }

  // ---- Creates ------------------------------------------------------------

  @isTest
  static void anUnmatchedRecordIsNotCreatedUnlessConfigured() {
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Name', 'name', PortalSyncConfig.DIR_HS_TO_SF, false)
      }
    );
    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(), // creates off
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'name' => 'Brand New Co',
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      new Map<Id, SObject>(),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();
    System.assertEquals(0, d.creates.size());
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_UNMATCHED'
      ]
    );
  }

  @isTest
  static void aCreatedRecordCarriesItsPortalAndIsHeldOutOfTheOutbox() {
    PortalSyncConfig.ObjectConfig cfg = accountConfig();
    cfg.inboundCreateUnmatched = true;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Name', 'name', PortalSyncConfig.DIR_HS_TO_SF, false)
      }
    );

    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      cfg,
      TRIBU,
      new List<Map<String, Object>>{
        row(
          'hs-1',
          new Map<String, Object>{
            'name' => 'Brand New Co',
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      new Map<Id, SObject>(),
      new Set<String>(),
      new Set<String>(),
      null
    );

    System.assertEquals(1, d.creates.size());
    Account created = (Account) d.creates[0];
    System.assertEquals('Brand New Co', created.Name);
    System.assertEquals(
      TRIBU,
      created.Portal__c,
      'the originating portal is stamped on create'
    );
    System.assertEquals(
      PortalSyncConfig.STATUS_AWAITING_WRITEBACK,
      created.HS_Sync_Status__c,
      'and the record is held out of the outbox until its id reaches HubSpot, ' +
      'or the push would create a SECOND HubSpot record beside the original'
    );
    System.assertEquals(
      'hs-1',
      d.createHsIds[0],
      'the HubSpot id is kept so the write-back can be queued after the insert'
    );
  }

  @isTest
  static void aCreateIsRefusedWhenNoMappingSuppliesARequiredField() {
    // Reported by field name, before DML, rather than as an opaque
    // REQUIRED_FIELD_MISSING against a record that does not exist yet.
    PortalSyncConfig.ObjectConfig cfg = accountConfig();
    cfg.inboundCreateUnmatched = true;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping(
          'Description',
          'description',
          PortalSyncConfig.DIR_HS_TO_SF,
          false
        )
      }
    );

    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      cfg,
      TRIBU,
      new List<Map<String, Object>>{
        row(
          'hs-1',
          new Map<String, Object>{
            'description' => 'no name mapped',
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      new Map<Id, SObject>(),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(0, d.creates.size());
    List<PortalSyncDeadLetter__c> rows = [
      SELECT Error__c
      FROM PortalSyncDeadLetter__c
      WHERE Operation__c = 'INBOUND_CREATE_INCOMPLETE'
    ];
    System.assertEquals(1, rows.size());
    System.assert(
      rows[0].Error__c.contains('Name'),
      'the message must name the field an admin has to map, was: ' +
      rows[0].Error__c
    );
  }

  @isTest
  static void aQueuedWriteBackBlocksASecondCreateForTheSameHubSpotRecord() {
    // The duplicate-creation hazard: without this guard a replay inside the
    // overlap window creates a second Salesforce record for one HubSpot record.
    PortalSyncConfig.ObjectConfig cfg = accountConfig();
    cfg.inboundCreateUnmatched = true;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Name', 'name', PortalSyncConfig.DIR_HS_TO_SF, false)
      }
    );

    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      cfg,
      TRIBU,
      new List<Map<String, Object>>{
        row(
          'hs-1',
          new Map<String, Object>{
            'name' => 'Already Created',
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      new Map<Id, SObject>(),
      new Set<String>(),
      new Set<String>{ 'hs-1' }, // write-back still queued
      null
    );
    System.assertEquals(
      0,
      d.creates.size(),
      'its Salesforce record already exists; creating another would duplicate it'
    );
  }

  @isTest
  static void aCreateTakesItsLookupFromTheHubSpotAssociation() {
    PortalSyncConfig.ObjectConfig cfg = accountConfig();
    cfg.inboundCreateUnmatched = true;
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Name', 'name', PortalSyncConfig.DIR_HS_TO_SF, false)
      }
    );
    Account parent = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);

    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      cfg,
      TRIBU,
      new List<Map<String, Object>>{
        row(
          'hs-1',
          new Map<String, Object>{
            'name' => 'Child Co',
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      new Map<Id, SObject>(),
      new Set<String>(),
      new Set<String>(),
      new Map<String, Map<String, Object>>{
        'hs-1' => new Map<String, Object>{ 'ParentId' => parent.Id }
      }
    );
    System.assertEquals(1, d.creates.size());
    System.assertEquals(
      parent.Id,
      ((Account) d.creates[0]).ParentId,
      'a record created from HubSpot must not be born orphaned -- an empty ' +
      'desired set is what makes the association pass strip its real links'
    );
  }

  // ---- Type conversion ----------------------------------------------------

  @isTest
  static void anEpochDateConvertsWithoutADayShift() {
    // 2026-08-22T00:00:00Z. dateGmt() is required: date() would render this as
    // the 21st for any user west of GMT, and a batch runs as whoever scheduled
    // it. The outbound formatDate exists for the mirror image of this bug.
    Datetime utcMidnight = Datetime.newInstanceGmt(2026, 8, 22, 0, 0, 0);
    System.assertEquals(
      Date.newInstance(2026, 8, 22),
      PortalInboundMapper.parseDate(String.valueOf(utcMidnight.getTime())),
      'an epoch date must land on the same calendar day it denotes'
    );
    System.assertEquals(
      Date.newInstance(2026, 8, 22),
      PortalInboundMapper.parseDate('2026-08-22'),
      'and the plain ISO form parses too'
    );
  }

  @isTest
  static void hubSpotTimestampsParseInBothWireForms() {
    Datetime expected = Datetime.newInstanceGmt(2026, 8, 22, 14, 3, 11);
    System.assertEquals(
      expected,
      HubSpotService.parseHubSpotDatetime(String.valueOf(expected.getTime())),
      'epoch milliseconds'
    );
    System.assertEquals(
      expected,
      HubSpotService.parseHubSpotDatetime('2026-08-22T14:03:11Z'),
      'and ISO-8601 with a Z -- never Datetime.valueOf, which would apply the ' +
      'running users time zone and shift this by hours'
    );
    System.assertEquals(null, HubSpotService.parseHubSpotDatetime('nonsense'));
    System.assertEquals(null, HubSpotService.parseHubSpotDatetime(null));
  }

  @isTest
  static void anInvalidPicklistValueIsRefusedRatherThanFailingTheDml() {
    // Without this, a portal-scoped HubSpot id landing in a restricted picklist
    // fails the DML for that record on EVERY poll, forever.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Type', 'company_type', PortalSyncConfig.DIR_HS_TO_SF, false)
      }
    );

    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'company_type' => 'b2f7a1c0-not-a-picklist-value',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(
      0,
      d.updates.size(),
      'the raw value must not be written'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_VALUE_MAP'
      ],
      'and the fix -- add a value map row -- is reported'
    );
  }

  @isTest
  static void anUnwritableFieldIsRefused() {
    // CreatedDate exists but is not updateable, so it reaches the mapper and is
    // refused there. A cross-object path never gets that far -- it is dropped at
    // config load (see aMappingRowNamingAMissingFieldIsIgnoredNotFatal).
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('CreatedDate', 'created', PortalSyncConfig.DIR_HS_TO_SF, false)
      }
    );

    Test.startTest();
    PortalInboundMapper.Decision d = PortalInboundMapper.decide(
      accountConfig(),
      TRIBU,
      new List<Map<String, Object>>{
        row(
          '1',
          new Map<String, Object>{
            'created' => '2026-01-01',
            'salesforceaccountid_bl' => a.Id,
            'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
          }
        )
      },
      null,
      reread(a.Id),
      new Set<String>(),
      new Set<String>(),
      null
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(0, d.updates.size());
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'INBOUND_NOT_WRITEABLE'
      ],
      'a field that exists but cannot be written is refused at map time'
    );
  }

  // ---- The provenance stamp ------------------------------------------------

  @isTest
  static void anEditToAHubSpotOwnedFieldMovesProvenanceWithoutQueueingAPush() {
    // The two questions the trigger answers over two different field sets. Uses
    // the real shipped metadata, where Account.Description is HS_to_SF.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    Datetime before = [
      SELECT HS_Content_Changed__c
      FROM Account
      WHERE Id = :a.Id
    ]
    .HS_Content_Changed__c;

    Test.startTest();
    a.Description = 'edited in Salesforce';
    update a;
    Test.stopTest();

    Account after = [
      SELECT HS_Sync_Status__c, HS_Content_Changed__c
      FROM Account
      WHERE Id = :a.Id
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c,
      'a HubSpot-owned field must not enqueue an outbound push'
    );
    System.assert(
      after.HS_Content_Changed__c != null &&
      (before == null ||
      after.HS_Content_Changed__c >= before),
      'but it must still move the provenance clock, or Salesforce would look ' +
      'stale and lose the next conflict it should win'
    );
  }

  @isTest
  static void aSalesforceOwnedEditStillQueuesAPush() {
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    Test.startTest();
    a.Phone = '555-0100';
    update a;
    Test.stopTest();
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id]
      .HS_Sync_Status__c,
      'Phone is Salesforce-owned, so the existing behaviour must be unchanged'
    );
  }

  // ---- Batch, end to end ---------------------------------------------------

  @isTest
  static void theSearchRequestCarriesTheWatermarkAndOnlyInboundProperties() {
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Watermark__c = System.now().addHours(-2)
    );
    // Read the STORED value back: Salesforce persists DateTime to second
    // precision, so comparing against the in-memory System.now() would fail on
    // the dropped milliseconds rather than on anything meaningful.
    Datetime watermark = [SELECT Watermark__c FROM HS_Inbound_Cursor__c]
    .Watermark__c;

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.addSearchResult(
      'hs-1',
      new Map<String, Object>{
        'description' => 'from HubSpot',
        'salesforceaccountid_bl' => a.Id,
        'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
      }
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new AccountInboundBatch(), 1);
    Test.stopTest();

    System.assertEquals(
      1,
      mock.capturedSearchBodies.size(),
      'one portal polled'
    );
    Map<String, Object> body = mock.capturedSearchBodies[0];

    List<Object> groups = (List<Object>) body.get('filterGroups');
    Map<String, Object> filter = (Map<String, Object>) ((List<Object>) ((Map<String, Object>) groups[0])
      .get('filters'))[0];
    System.assertEquals('hs_lastmodifieddate', filter.get('propertyName'));
    System.assertEquals(
      'GTE',
      filter.get('operator'),
      'GTE, because the window is deliberately rewound to absorb search-index lag'
    );
    Long sent = Long.valueOf(String.valueOf(filter.get('value')));
    System.assertEquals(
      watermark.addSeconds(-300).getTime(),
      sent,
      'the filter must be the watermark minus the overlap, as epoch millis'
    );

    Map<String, Object> sortSpec = (Map<String, Object>) ((List<Object>) body.get(
      'sorts'
    ))[0];
    System.assertEquals(
      'ASCENDING',
      sortSpec.get('direction'),
      'oldest first, which is what makes the watermark advance resumable'
    );

    Set<String> requested = new Set<String>();
    for (Object p : (List<Object>) body.get('properties')) {
      requested.add(String.valueOf(p));
    }
    System.assert(
      requested.contains('description'),
      'the HubSpot-owned property is requested'
    );
    System.assert(
      !requested.contains('phone'),
      'a Salesforce-owned property must NOT be -- inbound has no business reading it'
    );
  }

  @isTest
  static void inboundAppliesAHubSpotValueWithoutQueueingAPushBack() {
    // The whole loop, end to end, against the real shipped metadata: HubSpot
    // owns Account.Description, so the value lands and nothing bounces back.
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Watermark__c = System.now().addHours(-2)
    );

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.addSearchResult(
      'hs-1',
      new Map<String, Object>{
        'description' => 'written by a HubSpot user',
        'salesforceaccountid_bl' => a.Id,
        'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
      }
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new AccountInboundBatch(), 1);
    Test.stopTest();

    Account after = [
      SELECT Description, HS_Sync_Status__c
      FROM Account
      WHERE Id = :a.Id
    ];
    System.assertEquals(
      'written by a HubSpot user',
      after.Description,
      'the HubSpot value must reach Salesforce'
    );
    System.assertEquals(
      PortalSyncConfig.STATUS_SYNCED,
      after.HS_Sync_Status__c,
      'and must NOT re-stamp Pending -- that echo is the loop the design exists to prevent'
    );

    HS_Inbound_Cursor__c cursor = [
      SELECT Watermark__c, Last_Status__c, Records_Seen__c, Records_Applied__c
      FROM HS_Inbound_Cursor__c
    ];
    System.assertEquals(PortalSyncConfig.INBOUND_OK, cursor.Last_Status__c);
    System.assertEquals(1, cursor.Records_Seen__c);
    System.assertEquals(1, cursor.Records_Applied__c);
    System.assert(cursor.Watermark__c != null, 'the watermark advanced');
  }

  @isTest
  static void aSearchFailureLeavesTheWatermarkWhereItWas() {
    // Records we never saw must be retried, never stepped over.
    Datetime watermark = System.now().addHours(-2);
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Watermark__c = watermark
    );

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.failSearch = true;
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new AccountInboundBatch(), 1);
    Test.stopTest();

    HS_Inbound_Cursor__c cursor = [
      SELECT Watermark__c, Last_Status__c
      FROM HS_Inbound_Cursor__c
    ];
    System.assertEquals(PortalSyncConfig.INBOUND_FAILED, cursor.Last_Status__c);
    System.assertEquals(
      watermark,
      cursor.Watermark__c,
      'the watermark must not move when the search itself failed'
    );
    System.assert(
      ![
          SELECT Id
          FROM PortalSyncDeadLetter__c
          WHERE Operation__c = 'INBOUND_SEARCH'
        ]
        .isEmpty(),
      'and the failure is recorded'
    );
  }

  @isTest
  static void aPausedCursorIsNotPolled() {
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Paused__c = true
    );
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new AccountInboundBatch(), 1);
    Test.stopTest();

    System.assertEquals(
      0,
      mock.searchCallCount,
      'Paused__c is the per-portal kill switch and must stop the callout entirely'
    );
  }

  @isTest
  static void pagingContinuesUntilTheCursorRunsOut() {
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Watermark__c = System.now().addHours(-2)
    );

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    // 150 rows against a 100-row page size forces a second page.
    for (Integer i = 0; i < 150; i++) {
      mock.addSearchResult(
        'hs-' + i,
        new Map<String, Object>{
          'description' => 'row ' + i,
          'salesforceaccountid_bl' => (i == 0 ? String.valueOf(a.Id) : ''),
          'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
        }
      );
    }
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new AccountInboundBatch(), 1);
    Test.stopTest();

    System.assertEquals(
      2,
      mock.searchCallCount,
      '150 rows at 100 per page must be fetched in two calls'
    );
    System.assertEquals(
      150,
      [SELECT Records_Seen__c FROM HS_Inbound_Cursor__c].Records_Seen__c
    );
  }

  @isTest
  static void theSchedulerSeedsOneCursorPerPollablePortal() {
    // Cursor rows are seeded by the scheduler, not the batch: a batch's start()
    // cannot do DML, and it means the rows are visible and pausable before any
    // polling happens.
    Test.startTest();
    PortalInboundScheduler.ensureCursors(
      new List<PortalSyncConfig.ObjectConfig>{
        PortalSyncConfig.objectConfig('Account')
      }
    );
    // Twice, to prove it is idempotent -- two overlapping schedulers must not
    // produce duplicate rows.
    PortalInboundScheduler.ensureCursors(
      new List<PortalSyncConfig.ObjectConfig>{
        PortalSyncConfig.objectConfig('Account')
      }
    );
    Test.stopTest();

    List<HS_Inbound_Cursor__c> cursors = [
      SELECT Cursor_Key__c, Portal__c
      FROM HS_Inbound_Cursor__c
      WHERE SObject_Name__c = 'Account'
    ];
    System.assertEquals(
      PortalSyncConfig.allPortalValues().size(),
      cursors.size(),
      'one row per enabled portal, and seeding twice must not duplicate them'
    );
  }

  @isTest
  static void anExistingCursorKeepsItsWatermarkWhenReseeded() {
    Datetime watermark = System.now().addDays(-3);
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Watermark__c = watermark,
      Paused__c = true
    );

    Test.startTest();
    PortalInboundScheduler.ensureCursors(
      new List<PortalSyncConfig.ObjectConfig>{
        PortalSyncConfig.objectConfig('Account')
      }
    );
    Test.stopTest();

    HS_Inbound_Cursor__c after = [
      SELECT Watermark__c, Paused__c
      FROM HS_Inbound_Cursor__c
      WHERE Portal__c = :TRIBU
    ];
    System.assertEquals(
      watermark,
      after.Watermark__c,
      'reseeding writes only identity fields, so progress is never reset'
    );
    System.assertEquals(true, after.Paused__c, 'nor is an admin pause undone');
  }

  // ---- The sf-id write-back ------------------------------------------------

  @isTest
  static void theWriteBackUsesTheHubSpotIdAndThenReleasesTheRecord() {
    Account a = new Account(
      Name = 'Created inbound',
      Portal__c = TRIBU,
      HS_Sync_Status__c = PortalSyncConfig.STATUS_AWAITING_WRITEBACK
    );
    insert a;
    a.HS_Sync_Status__c = PortalSyncConfig.STATUS_AWAITING_WRITEBACK;
    update a;

    insert new HS_Inbound_Stamp__c(
      Record_Id__c = a.Id,
      HubSpot_Id__c = 'hs-99',
      Portal__c = TRIBU,
      SObject_Name__c = 'Account',
      Status__c = PortalSyncConfig.STATUS_PENDING,
      Retry_Count__c = 0
    );

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new PortalInboundStampBatch(), 100);
    Test.stopTest();

    System.assert(
      mock.capturedUpdateProps.containsKey('hs-99'),
      'the id must be written by HubSpot object id via batch/update -- an upsert ' +
      'on the sf-id property would not match and would create a SECOND HubSpot record'
    );
    System.assertEquals(
      a.Id,
      mock.capturedUpdateProps.get('hs-99').get('salesforceaccountid_bl'),
      'carrying the new Salesforce id'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Inbound_Stamp__c],
      'a drained stamp row is deleted'
    );
    System.assertEquals(
      PortalSyncConfig.STATUS_PENDING,
      [SELECT HS_Sync_Status__c FROM Account WHERE Id = :a.Id]
      .HS_Sync_Status__c,
      'and the record is released into the outbox so it can now fan out'
    );
  }

  @isTest
  static void aFailedWriteBackRetriesAndKeepsItsRow() {
    Account a = new Account(Name = 'Created inbound', Portal__c = TRIBU);
    insert a;
    insert new HS_Inbound_Stamp__c(
      Record_Id__c = a.Id,
      HubSpot_Id__c = 'hs-99',
      Portal__c = TRIBU,
      SObject_Name__c = 'Account',
      Status__c = PortalSyncConfig.STATUS_PENDING,
      Retry_Count__c = 0
    );

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.failStampBack = true;
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new PortalInboundStampBatch(), 100);
    Test.stopTest();

    HS_Inbound_Stamp__c row = [
      SELECT Status__c, Retry_Count__c
      FROM HS_Inbound_Stamp__c
    ];
    System.assertEquals(
      PortalSyncConfig.STATUS_FAILED,
      row.Status__c,
      'the row is kept, never dropped -- dropping it would permanently reopen ' +
      'the duplicate-creation window'
    );
    System.assertEquals(1, row.Retry_Count__c);
    System.assert(
      ![
          SELECT Id
          FROM PortalSyncDeadLetter__c
          WHERE Operation__c = 'INBOUND_STAMP'
        ]
        .isEmpty()
    );
  }

  // ---- Outbound deference (the other half of the conflict rule) -----------

  @isTest
  static void theDeadLetterSinkNeverEscalatesAFailureIntoAnOutage() {
    // flush() is a diagnostic sink: failing to record a failure must not fail
    // the work that was reporting it. A bare insert would roll back the caller's
    // whole transaction, cursor advance included.
    PortalSyncDeadLetter.log(
      'Account',
      'SEARCH',
      TRIBU,
      'INBOUND_SEARCH',
      'x'.repeat(1500) // longer than Error__c
    );
    Test.startTest();
    PortalSyncDeadLetter.flush();
    Test.stopTest();
    List<PortalSyncDeadLetter__c> rows = [
      SELECT Error__c
      FROM PortalSyncDeadLetter__c
    ];
    System.assertEquals(1, rows.size());
    System.assertEquals(
      1000,
      rows[0].Error__c.length(),
      'truncated to the real field capacity, not the old 255'
    );
  }

  /** An Account that exists only in memory. Needed because a callout cannot
   *  follow DML in the same transaction, so a synchronous router test must not
   *  insert anything. */
  private static Account inMemoryAccount(String portal, Datetime provenance) {
    return new Account(
      Id = '001000000000001AAA',
      Name = 'Acme',
      Phone = '555-0100',
      Portal__c = portal,
      HS_Content_Changed__c = provenance
    );
  }

  @isTest
  static void outboundDefersToANewerHubSpotValue() {
    // The other half of newest-modified-wins, and the reason it is a rule at all
    // rather than a coin flip. Without this the outbox pushes the Salesforce
    // value and bumps hs_lastmodifieddate, destroying both the HubSpot edit and
    // the evidence that it was newer -- all before inbound ever runs.
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Phone', 'phone', PortalSyncConfig.DIR_BIDIRECTIONAL, true)
      }
    );
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.compareProps.put(
      '001000000000001AAA',
      new Map<String, Object>{
        'phone' => 'edited in HubSpot',
        'hs_lastmodifieddate' => String.valueOf(
          System.now().addDays(1).getTime()
        )
      }
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Map<Id, Boolean> result = PortalRouter.syncRecords(
      accountConfig(),
      new List<SObject>{ inMemoryAccount(TRIBU, System.now().addDays(-1)) },
      false
    );
    Test.stopTest();

    System.assertEquals(
      true,
      result.get('001000000000001AAA'),
      'the record still syncs -- only the contested property is withheld'
    );
    Map<String, Object> sent = mock.capturedUpsertProps.get(
      '001000000000001AAA'
    );
    System.assert(
      sent != null && !sent.containsKey('phone'),
      'a Bidirectional property whose HubSpot copy is newer must NOT be pushed; sent: ' +
      sent
    );
  }

  @isTest
  static void outboundStillPushesWhenSalesforceIsNewer() {
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Phone', 'phone', PortalSyncConfig.DIR_BIDIRECTIONAL, true)
      }
    );
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.compareProps.put(
      '001000000000001AAA',
      new Map<String, Object>{
        'phone' => 'stale',
        'hs_lastmodifieddate' => String.valueOf(
          System.now().addDays(-5).getTime()
        )
      }
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    PortalRouter.syncRecords(
      accountConfig(),
      new List<SObject>{ inMemoryAccount(TRIBU, System.now()) },
      false
    );
    Test.stopTest();

    System.assertEquals(
      '555-0100',
      mock.capturedUpsertProps.get('001000000000001AAA').get('phone'),
      'Salesforce is newer, so its value goes out normally'
    );
  }

  @isTest
  static void outboundFailsTheRecordWhenTheComparisonCannotBeRead() {
    // Neither pushing nor silently withholding is acceptable here. Pushing would
    // clobber a value we could not verify; withholding while letting the upsert
    // succeed would flip the record to Synced and lose the Salesforce edit for
    // good. Failing leaves it to retry.
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Phone', 'phone', PortalSyncConfig.DIR_BIDIRECTIONAL, true)
      }
    );
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.failCompareRead = true;
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Map<Id, Boolean> result = PortalRouter.syncRecords(
      accountConfig(),
      new List<SObject>{ inMemoryAccount(TRIBU, System.now()) },
      false
    );
    PortalSyncDeadLetter.flush();
    Test.stopTest();

    System.assertEquals(
      false,
      result.get('001000000000001AAA'),
      'the record must be failed so it retries'
    );
    System.assert(
      mock.capturedUpsertProps.isEmpty(),
      'and it must not be pushed at all'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM PortalSyncDeadLetter__c
        WHERE Operation__c = 'BIDI_COMPARE'
      ]
    );
  }

  @isTest
  static void anOutboundOnlyObjectPaysNoComparisonCost() {
    // hasBidirectionalFields() is the cheap up-front test that keeps the extra
    // read at zero until someone deliberately opts a field into two-way sync.
    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('Phone', 'phone', PortalSyncConfig.DIR_SF_TO_HS, true)
      }
    );
    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.compareProps.put(
      '001000000000001AAA',
      new Map<String, Object>{
        'hs_lastmodifieddate' => String.valueOf(
          System.now().addDays(1).getTime()
        )
      }
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    PortalRouter.syncRecords(
      accountConfig(),
      new List<SObject>{ inMemoryAccount(TRIBU, System.now().addDays(-1)) },
      false
    );
    Test.stopTest();

    System.assertEquals(
      '555-0100',
      mock.capturedUpsertProps.get('001000000000001AAA').get('phone'),
      'with nothing Bidirectional, no comparison happens and the push is unchanged'
    );
  }

  // ---- Blank confirmation --------------------------------------------------

  @isTest
  static void anEmptyValueIsConfirmedBeforeAnythingIsCleared() {
    // Search may OMIT an empty property rather than report it, which makes
    // "cleared in HubSpot" and "not told" indistinguishable from search alone.
    // batch/read answers explicitly, so it is consulted before Salesforce data
    // is destroyed. Uses the shipped metadata (Account.Description is HS_to_SF
    // with Inbound_Clears__c on).
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'to be cleared';
    update a;
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Watermark__c = System.now().addHours(-2)
    );

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    // 'description' is ABSENT from the search response...
    mock.addSearchResult(
      'hs-1',
      new Map<String, Object>{
        'salesforceaccountid_bl' => a.Id,
        'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
      }
    );
    // ...and the authoritative read says it really is empty.
    mock.confirmReadProps.put(
      'hs-1',
      new Map<String, Object>{ 'description' => null }
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new AccountInboundBatch(), 1);
    Test.stopTest();

    System.assertEquals(
      1,
      mock.confirmReadCallCount,
      'the missing property must trigger exactly one confirmation read'
    );
    System.assertEquals(
      null,
      [SELECT Description FROM Account WHERE Id = :a.Id].Description,
      'confirmed empty means a deliberate clear, so it is applied'
    );
  }

  @isTest
  static void anUnconfirmableBlankIsLeftAlone() {
    // If the confirmation read fails we know nothing, and "nothing" must never
    // be read as "clear it".
    Account a = insertAccount(TRIBU, PortalSyncConfig.STATUS_SYNCED);
    a.Description = 'must survive';
    update a;
    insert new HS_Inbound_Cursor__c(
      Cursor_Key__c = PortalInboundScheduler.cursorKey('Account', TRIBU),
      SObject_Name__c = 'Account',
      Portal__c = TRIBU,
      Watermark__c = System.now().addHours(-2)
    );

    HubSpotCalloutMock mock = new HubSpotCalloutMock();
    mock.addSearchResult(
      'hs-1',
      new Map<String, Object>{
        'salesforceaccountid_bl' => a.Id,
        'hs_lastmodifieddate' => String.valueOf(System.now().getTime())
      }
    );
    mock.failConfirmRead = true;
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    Database.executeBatch(new AccountInboundBatch(), 1);
    Test.stopTest();

    System.assertEquals(
      'must survive',
      [SELECT Description FROM Account WHERE Id = :a.Id].Description,
      'an unconfirmable blank must not destroy data'
    );
  }

  // ---- Config resilience ---------------------------------------------------

  @isTest
  static void aMappingRowNamingAMissingFieldIsIgnoredNotFatal() {
    // One bad row would otherwise reach the outbox SOQL, the reconciliation SOQL
    // and the trigger's change detection -- breaking every save and every sync
    // of the object, which is far worse than the field simply not syncing.
    System.assertEquals(
      false,
      PortalSyncConfig.fieldExists('Account', 'NoSuchField__c'),
      'a missing field must be detected'
    );
    System.assertEquals(
      false,
      PortalSyncConfig.fieldExists('Account', 'Owner.Email'),
      'and so must a cross-object path, which record.get() could never traverse'
    );
    System.assertEquals(true, PortalSyncConfig.fieldExists('Account', 'Phone'));

    seedFieldMaps(
      new List<PortalSyncConfig.FieldMap>{
        mapping('NoSuchField__c', 'ghost', PortalSyncConfig.DIR_HS_TO_SF, true),
        mapping('Phone', 'phone', PortalSyncConfig.DIR_SF_TO_HS, true)
      }
    );
    System.assertEquals(
      1,
      PortalSyncConfig.fieldMapsFor('Account').size(),
      'the unusable row is dropped'
    );
    System.assert(
      !PortalSyncConfig.mappedSfFields('Account').contains('NoSuchField__c'),
      'and never reaches a SOQL field list'
    );
  }

  // ---- Scheduling ----------------------------------------------------------

  @isTest
  static void theSchedulerRunsAndLaunchesTheWriteBackDrain() {
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());
    Test.startTest();
    new PortalInboundScheduler().execute(null);
    Test.stopTest();
    // Nothing is polled because Inbound_Active__c ships false, which is the
    // point: deploying and scheduling inbound changes nothing until an admin
    // opts an object in.
    System.assertEquals(
      0,
      [SELECT COUNT() FROM HS_Inbound_Cursor__c],
      'an object that has not opted in gets no cursor rows'
    );
  }

  @isTest
  static void bothInboundBatchesAreConstructible() {
    // The per-object subclasses exist only to give the scheduler a distinct
    // AsyncApexJob.ApexClass.Name, so all they need to prove is that they wire
    // themselves to the right config.
    System.assertNotEquals(null, new AccountInboundBatch());
    System.assertNotEquals(null, new OpportunityInboundBatch());
    try {
      new PortalInboundBatch('NotASyncedObject');
      System.assert(false, 'an unconfigured object must be rejected loudly');
    } catch (IllegalArgumentException e) {
      System.assert(e.getMessage().contains('NotASyncedObject'));
    }
  }

  @isTest
  static void theWriteBackDrainReportsAnUnconfiguredObject() {
    // Config removed after a row was queued: every row is treated as failed so
    // an admin can restore the config and let it retry, rather than the
    // write-back being dropped silently.
    insert new HS_Inbound_Stamp__c(
      Record_Id__c = '001000000000001AAA',
      HubSpot_Id__c = 'hs-1',
      Portal__c = TRIBU,
      SObject_Name__c = 'NoLongerConfigured',
      Status__c = PortalSyncConfig.STATUS_PENDING,
      Retry_Count__c = 0
    );
    Test.setMock(HttpCalloutMock.class, new HubSpotCalloutMock());

    Test.startTest();
    Database.executeBatch(new PortalInboundStampBatch(), 100);
    Test.stopTest();

    System.assertEquals(
      PortalSyncConfig.STATUS_FAILED,
      [SELECT Status__c FROM HS_Inbound_Stamp__c].Status__c,
      'the row is retained for retry, never dropped'
    );
  }

  @isTest
  static void theOverlapGuardCoversBothDirections() {
    // Concurrency between the two directions loses updates invisibly, so each
    // scheduler asks about both class names.
    PortalSyncConfig.ObjectConfig cfg = PortalSyncConfig.objectConfig(
      'Account'
    );
    Set<String> both = PortalSyncJobs.bothDirections(cfg);
    System.assert(both.contains('AccountOutboxBatch'));
    System.assert(both.contains('AccountInboundBatch'));
    System.assertEquals(
      false,
      PortalSyncJobs.isAnyRunning(new Set<String>{ null, '' }),
      'blank class names contribute nothing rather than throwing'
    );
    System.assertEquals(false, PortalSyncJobs.isRunning('NoSuchBatchClass'));
  }
}
