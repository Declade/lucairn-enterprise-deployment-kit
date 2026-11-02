# Lucairn ServiceNow directory app

The ServiceNow side of the kit's ServiceNow mode (INSTALL.md § "ServiceNow mode
(off by default)"). It is a scoped application, `x_1620539_lucdir` ("Lucairn
Directory Fingerprints", version 0.2.0), that runs **on your own ServiceNow
instance**: it publishes keyed fingerprints of the names of your instance's
users, and optionally a field map, to the Lucairn install that reads them with
a dedicated reader account. The fingerprint key is generated on your instance
and stays in your environment.

**Off by default, on both sides.** After the import the app's switch
`x_1620539_lucdir.enabled` is `false`; the kit's mode stays off until
`customer.env` binds a key (INSTALL.md, "Turn it on").

| File | What it is |
|---|---|
| `lucairn-directory-update-set.xml` | the app's update set (85 update records) |
| `scheduled_job.js`, `companion_job.js` | the scripts of the app's two scheduled jobs, which the update set does not carry |
| `PROVENANCE` | source repository, commit, path and the sha256 of every file here |
| `LICENSE` | Business Source License 1.1, the same licence and parameters as this kit |

Every file is copied byte for byte from `Declade/lucairn-servicenow-directory`
at the commit in `PROVENANCE` (the update set is built there from the app's
source). `bin/lucairn doctor` (mode on), `bin/lucairn bundle verify` and the
kit's release script refuse a file whose sha256 differs from `PROVENANCE`.

Install (details and the checks to make before switching on: INSTALL.md,
"The directory app (on your ServiceNow instance)"):

1. *Retrieved Update Sets → Import Update Set from XML* with
   `lucairn-directory-update-set.xml`, preview, commit.
2. Create the two scheduled jobs in the app: "Lucairn directory: publish
   fingerprints" (every 15 minutes, `scheduled_job.js`) and "Lucairn
   directory: publish companion" (every minute, `companion_job.js`).
3. In *Scripts – Background* with the scope selector on `x_1620539_lucdir`, run
   `gs.info(JSON.stringify(new x_1620539_lucdir.LucairnDirectoryPublisher().keyStoreCheck()))`
   and continue only when it prints `"closed":true` and a count query on the
   key table by an account without any role answers 403.
4. Create the reader account: identity type *Machine*, *Web service access
   only*, role `x_1620539_lucdir.reader` and nothing else. Review who can grant
   that role or impersonate the account: each of them could fetch the key.
5. Set `x_1620539_lucdir.enabled` to `true`; after the first job run,
   `GET /api/x_1620539_lucdir/directory/bundle` as the reader answers 200.

The reader account's login becomes the kit's stored `login.json`
(INSTALL.md, "Turn it on", step 4).
