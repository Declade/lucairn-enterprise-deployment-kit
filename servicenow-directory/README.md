# Lucairn ServiceNow directory app

The ServiceNow side of the kit's ServiceNow mode (INSTALL.md § "ServiceNow mode
(off by default)"). It is a scoped application, `x_1620539_lucdir` ("Lucairn
Directory Fingerprints"), that runs **on your own ServiceNow instance**: it
publishes keyed fingerprints of the names of your instance's users, and a field
map, to the Lucairn install that reads them with a dedicated reader account.
The fingerprint key is generated on your instance and stays in your environment.

- **Licence:** Business Source License 1.1, the same licence and parameters as
  this kit (see the kit's `LICENSE`).
- **Source:** `Declade/lucairn-servicenow-directory`; contract version and test
  vectors are named there.
- **File:** `lucairn-directory-update-set.xml` — the platform's own update-set
  export of the app (*System Update Sets → Local Update Sets → Export to XML* on
  the instance that has it). Import it on your instance with *Retrieved Update
  Sets → Import Update Set from XML*, preview, commit.

What the import does **not** carry, and you do by hand (the app's install
guide, steps 3–8):

1. Create the two scheduled jobs in the app ("Lucairn directory: publish
   fingerprints", every 15 minutes; "Lucairn directory: publish companion",
   every minute).
2. In *Scripts – Background* with the scope selector on `x_1620539_lucdir`, run
   `gs.info(JSON.stringify(new x_1620539_lucdir.LucairnDirectoryPublisher().keyStoreCheck()))`
   and continue only when it prints `"closed":true`.
3. Create the reader account: identity type *Machine*, *Web service access
   only*, role `x_1620539_lucdir.reader` and nothing else. Review who can grant
   that role or impersonate the account: each of them could fetch the key.
4. Set `x_1620539_lucdir.enabled` to `true`; after the first job run,
   `GET /api/x_1620539_lucdir/directory/bundle` as the reader answers 200.

The reader account's login becomes the kit's stored `login.json`
(INSTALL.md, step 4).
