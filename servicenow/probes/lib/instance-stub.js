'use strict';

/*
 * A DOCUMENTED-SHAPE stub of the instance side.
 *
 * It supplies the four platform surfaces this application touches — the
 * property service, GlideRecord over the two application tables, RESTMessageV2,
 * and the extension-point scope the preprocessor hook is pasted into — and
 * nothing else. Every Script Include underneath is the REAL one: the probes
 * exercise the real fail-closed decision, the real client, the real evidence
 * writer and the real hook body.
 *
 * ⚠️ EVERY SHAPE HERE IS A DOCUMENTED HYPOTHESIS, not an observation. The
 * extension-point shapes are the four the hook enumerates (and
 * ../../src/records/properties.md documents), each labelled ADJUST-ON-PDI in
 * the hook's own header. A probe passing against this stub says the probe
 * works; it says nothing about an instance. **Instance validation pending.**
 *
 * The platform fakes for GlideRecord come from ../../test/mocks/servicenow.js
 * rather than being re-implemented here, so the probe kit and the unit tests
 * cannot drift into two different ideas of how the platform behaves.
 */

const vm = require('node:vm');

const { FakeTable, glideRecordSeam } = require('../../test/mocks/servicenow');
const LucairnConfig = require('../../src/script_includes/LucairnConfig');
const LucairnEvidence = require('../../src/script_includes/LucairnEvidence');
const LucairnClient = require('../../src/script_includes/LucairnClient');
const LucairnSha256 = require('../../src/script_includes/LucairnSha256');
const LucairnNowAssistAdapter = require('../../src/script_includes/LucairnNowAssistAdapter');
const LucairnSkillGuard = require('../../src/script_includes/LucairnSkillGuard');

const { restMessageFactory } = require('./sync-http');

/** Every destination the hook recognises, in the order its header lists them. */
const DESTINATIONS = ['bare_output', 'outputs_text', 'api_set_output', 'global_output'];

/**
 * Build the whole instance-side stack over stubbed platform APIs.
 *
 * @param {object} opts
 * @param {string} [opts.baseUrl]   where the Lucairn service stub is listening
 * @param {string} [opts.vendor]    the `lucairn.now_assist.vendor` value; pass
 *   '' to seed the unset-vendor fault, and any string to seed an unsupported one
 * @param {number} [opts.timeoutMs]
 * @param {string} [opts.errorMode] 'throw' | 'flag' — see ./sync-http.js
 * @param {object[]} [opts.policyRows]
 * @param {boolean} [opts.evidenceInsertFails]
 * @param {string[]} [opts.evidenceMissingFields]
 * @param {object} [opts.extraProps]
 */
function makeInstance(opts) {
    opts = opts || {};

    /* The SHIPPING transport, not the bring-up fallback: the REST Message record
     * holds the endpoint and the credential, and the script never sees a URL.
     * (Endpoint mode additionally requires https, which a local stub does not
     * serve — so probing through it would have meant either weakening a
     * validation rule or testing a mode customers do not ship.) */
    const props = Object.assign({
        [LucairnConfig.PROP.TRANSPORT]: 'rest_message',
        [LucairnConfig.PROP.REST_MESSAGE]: 'Lucairn Service',
        [LucairnConfig.PROP.FN_SANITIZE]: 'sanitizeOnly',
        [LucairnConfig.PROP.FN_SEAL]: 'sealCert',
        [LucairnConfig.PROP.TIMEOUT_MS]: String(opts.timeoutMs || 45000),
        [LucairnConfig.PROP.VENDOR]: opts.vendor === undefined ? 'openai' : opts.vendor
    }, opts.extraProps || {});

    const policyTable = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    (opts.policyRows || []).forEach((row) => policyTable.seed(row));

    const evidenceTable = new FakeTable(LucairnEvidence.TABLE);
    evidenceTable.insertShouldFail = opts.evidenceInsertFails === true;
    evidenceTable.missingFields = opts.evidenceMissingFields || [];

    const glideRecord = glideRecordSeam({
        [LucairnConfig.TABLE_SKILL_POLICY]: policyTable,
        [LucairnEvidence.TABLE]: evidenceTable
    });

    const logs = [];
    const log = (m) => { logs.push(String(m)); };
    const httpCalls = [];

    const config = new LucairnConfig({
        getProperty: (name, fallback) =>
            (Object.prototype.hasOwnProperty.call(props, name) ? props[name] : fallback),
        glideRecord: glideRecord,
        log: log
    });

    const evidence = new LucairnEvidence({
        glideRecord: glideRecord,
        log: log,
        now: () => '2026-09-18 00:00:00'
    });

    /* Stands in for the REST Message record's two functions. The paths are the
     * ones LucairnClient declares, so a rename there breaks the probe kit
     * rather than silently pointing it somewhere else. */
    const restFunctions = {
        sanitizeOnly: LucairnClient.PATH_SANITIZE,
        sealCert: LucairnClient.PATH_SEAL
    };

    let guidSeq = 0;
    const adapter = new LucairnNowAssistAdapter({
        config: config,
        evidence: evidence,
        sha256: LucairnSha256,
        makeClient: (cfg) => {
            const factory = restMessageFactory({
                errorMode: opts.errorMode,
                baseUrl: opts.baseUrl || '',
                functions: restFunctions,
                calls: httpCalls
            });
            return new LucairnClient(cfg, {
                newMessage: factory,
                newNamedMessage: factory,
                log: log
            });
        },
        guid: () => 'corr_probe_' + (++guidSeq),
        log: log
    });

    return {
        props, adapter, config, evidence, logs, httpCalls,
        policyTable, evidenceTable,
        rows: () => evidenceTable.rows
    };
}

/**
 * Run the preprocessor hook exactly as pasted, in a context shaped like one of
 * the documented extension-point hypotheses.
 *
 * @param {object} opts
 * @param {string} opts.hookSource     the hook file's text
 * @param {object} opts.instance       from makeInstance()
 * @param {string} opts.input          the submitted text the platform exposes
 * @param {string} opts.declared       the value of
 *   `lucairn.now_assist.output_destination` — what the hook is TOLD to publish to
 * @param {string} opts.consumed       the destination the stub platform actually
 *   READS afterwards. Equal to `declared` on a correctly configured instance;
 *   different is the wrong-but-recognised fault, which the hook cannot detect
 *   (hook header § "Say the gap in that sentence out loud").
 * @param {string} [opts.skill]        the skill name the hook is pasted with
 * @returns {{raised: null|Error, consumedValue: *, context: object}}
 */
function runHookInExtensionPoint(opts) {
    const instance = opts.instance;
    const declared = opts.declared;
    const consumed = opts.consumed || opts.declared;

    if (DESTINATIONS.indexOf(consumed) === -1) {
        throw new Error('consumed destination is not one the hook recognises: ' + consumed);
    }

    /* The guard the hook constructs: the REAL Script Include over the REAL
     * adapter. Only the platform boundary underneath is stubbed. */
    function GuardStub() {
        return new LucairnSkillGuard({ adapter: instance.adapter, log: () => {} });
    }
    GuardStub.ERROR_PREFIX = LucairnSkillGuard.ERROR_PREFIX;
    GuardStub.UNCOVERED_ANNOTATION = LucairnSkillGuard.UNCOVERED_ANNOTATION;
    GuardStub.DECISION = LucairnSkillGuard.DECISION;

    const context = {
        LucairnSkillGuard: GuardStub,
        input: opts.input,
        gs: {
            getProperty: function (name, fallback) {
                if (name === LucairnConfig.PROP.OUTPUT_DESTINATION) {
                    return declared === undefined ? '' : declared;
                }
                return fallback;
            }
        }
    };

    /* Lay out the destination shapes. The CONSUMED one is seeded with the RAW
     * submission, because that is what an extension point holds before the hook
     * runs — which is exactly what makes a wrong-but-recognised declaration
     * detectable from outside the script and invisible from inside it. */
    const seed = (name) => (name === consumed ? opts.input : '');
    if (declared === 'bare_output' || consumed === 'bare_output') {
        context.output = seed('bare_output');
    }
    if (declared === 'outputs_text' || consumed === 'outputs_text') {
        context.outputs = { text: seed('outputs_text') };
    }
    if (declared === 'api_set_output' || consumed === 'api_set_output') {
        let slot = seed('api_set_output');
        context.api = {
            setOutput: function (v) { slot = v; },
            getOutput: function () { return slot; }
        };
    }
    /* `global_output` writes the global property and verifies by re-reading the
     * BARE identifier, so it needs NO pre-declared `output` binding — that is
     * the whole shape. Seeding one would turn it into `bare_output`. */

    let source = opts.hookSource;
    if (opts.skill) {
        source = source.replace(
            /var SKILL_NAME = '[^']*';/,
            "var SKILL_NAME = '" + opts.skill.replace(/'/g, "\\'") + "';");
    }

    let raised = null;
    try {
        vm.runInNewContext(source, context, { filename: 'genai-preprocessor.js' });
    } catch (e) {
        raised = e;
    }

    const readConsumed = () => {
        if (consumed === 'outputs_text') { return context.outputs ? context.outputs.text : undefined; }
        if (consumed === 'api_set_output') { return context.api ? context.api.getOutput() : undefined; }
        return context.output;
    };

    return { raised: raised, consumedValue: readConsumed(), context: context };
}

module.exports = { makeInstance, runHookInExtensionPoint, DESTINATIONS };
