'use strict';

/*
 * Minimal ServiceNow runtime shims so the Script Include sources in
 * servicenow/src/script_includes/ can be loaded and exercised under Node.
 *
 * This is a HARNESS, not a simulator. It provides only the globals the sources
 * touch at load time (`Class`) plus fakes the tests inject explicitly. Anything
 * a source reaches for that is not shimmed here should fail loudly rather than
 * quietly return undefined — that is how we find out we depended on a platform
 * API without noticing.
 */

/* ---- global shims ------------------------------------------------------- */

if (typeof global.Class === 'undefined') {
    global.Class = {
        create: function () {
            return function () {
                if (typeof this.initialize === 'function') {
                    this.initialize.apply(this, arguments);
                }
            };
        }
    };
}

if (typeof global.gs === 'undefined') {
    global.gs = {
        warn: function () { /* silenced in tests; assert on injected log spies */ },
        info: function () {},
        error: function () {},
        getProperty: function () {
            throw new Error('gs.getProperty called without an injected getProperty seam');
        },
        generateGUID: function () {
            throw new Error('gs.generateGUID called without an injected guid seam');
        }
    };
}

if (typeof global.GlideRecord === 'undefined') {
    global.GlideRecord = function () {
        throw new Error('GlideRecord constructed without an injected glideRecord seam');
    };
}

if (typeof global.GlideDateTime === 'undefined') {
    global.GlideDateTime = function () {
        throw new Error('GlideDateTime constructed without an injected now seam');
    };
}

if (typeof global.sn_ws === 'undefined') {
    global.sn_ws = {
        RESTMessageV2: function () {
            throw new Error('sn_ws.RESTMessageV2 constructed without an injected message seam');
        }
    };
}

/* ---- fakes -------------------------------------------------------------- */

/**
 * In-memory GlideRecord stand-in.
 *
 * Supports the narrow surface the sources use: initialize / setValue /
 * getValue / addQuery / setLimit / query / next / get / insert / update.
 */
function FakeTable(name) {
    this.name = name;
    this.rows = [];
    this._seq = 0;
    this.insertShouldFail = false;
    this.queryShouldThrow = false;

    /* --- states the round-1 gate found the old mock could not express ------
     *
     * A mock that can only produce well-behaved platform responses cannot
     * falsify a claim about misbehaving ones. Each flag below reproduces a
     * documented ServiceNow behaviour the sources now have to survive.
     */

    /* The table does not exist in this scope: isValid() is false. */
    this.tableInvalid = false;

    /* Field names the table does NOT have. isValidField() returns false for
     * these, and — the point — a query condition naming one is DROPPED rather
     * than matching nothing (see dropInvalidPredicates). */
    this.missingFields = [];

    /* Model the documented drop: conditions on a field in missingFields are
     * discarded from the filter, so the query returns rows it never asked for.
     * On by default because that is what the platform does. */
    this.dropInvalidPredicates = true;

    /* Ignore setLimit(), so more rows come back than were requested. */
    this.ignoreLimit = false;

    /* isValid() itself raises. */
    this.isValidShouldThrow = false;

    /* update() returns null — the platform's way of saying the write did not
     * happen (an ACL denial is the common cause). It does NOT raise. */
    this.updateShouldFail = false;
}

FakeTable.prototype.seed = function (row) {
    var copy = Object.assign({}, row);
    if (!copy.sys_id) {
        copy.sys_id = 'seed' + (++this._seq);
    }
    this.rows.push(copy);
    return copy;
};

FakeTable.prototype.newRecord = function () {
    var table = this;
    var pending = {};
    var queries = [];
    var cursor = -1;
    var matches = [];
    var limit = 0;
    /* `bound` is the in-memory working copy the script mutates; `boundRow` is
     * the stored row. The platform only merges one into the other on a
     * SUCCESSFUL update(), so a mock that let setValue() write straight through
     * to storage could not express a failed update at all. */
    var bound = null;
    var boundRow = null;

    function fieldExists(field) {
        return table.missingFields.indexOf(field) === -1;
    }

    return {
        initialize: function () { pending = {}; bound = null; boundRow = null; },
        setValue: function (field, value) {
            if (bound) { bound[field] = value; } else { pending[field] = value; }
        },
        getValue: function (field) {
            var src = bound || (matches[cursor] || {});
            return Object.prototype.hasOwnProperty.call(src, field) ? src[field] : null;
        },
        isValid: function () {
            if (table.isValidShouldThrow) {
                throw new Error('simulated isValid() failure on ' + table.name);
            }
            return !table.tableInvalid;
        },
        isValidField: function (field) { return fieldExists(field); },
        addQuery: function (field, value) { queries.push([field, value]); },
        setLimit: function (n) { limit = n; },
        query: function () {
            if (table.queryShouldThrow) {
                throw new Error('simulated query failure on ' + table.name);
            }
            /* THE DROP. A scoped GlideRecord discards a condition naming a field
             * the table does not have — it does not error and it does not match
             * nothing. A query whose only filters were dropped therefore selects
             * the whole table. */
            var effective = queries.filter(function (q) {
                return fieldExists(q[0]) || !table.dropInvalidPredicates;
            });
            matches = table.rows.filter(function (row) {
                return effective.every(function (q) {
                    /* Compare loosely: the fake stores booleans as booleans while
                     * the platform stores '1'/'0'. Both must match a query. */
                    var actual = row[q[0]];
                    if (typeof q[1] === 'boolean') {
                        return actual === q[1] || actual === (q[1] ? '1' : '0');
                    }
                    return String(actual) === String(q[1]);
                });
            });
            if (limit > 0 && !table.ignoreLimit) { matches = matches.slice(0, limit); }
            cursor = -1;
        },
        next: function () {
            cursor += 1;
            return cursor < matches.length;
        },
        get: function (sysId) {
            var found = table.rows.filter(function (r) { return r.sys_id === sysId; })[0];
            if (!found) { return false; }
            boundRow = found;
            bound = Object.assign({}, found);
            return true;
        },
        insert: function () {
            if (table.insertShouldFail) { return null; }
            var row = Object.assign({}, pending);
            row.sys_id = 'row' + (++table._seq);
            table.rows.push(row);
            return row.sys_id;
        },
        update: function () {
            if (table.updateShouldFail || !boundRow) { return null; }
            Object.assign(boundRow, bound);
            return boundRow.sys_id;
        }
    };
};

/**
 * @param {object} tables map of table name -> FakeTable
 * @returns {function(string): object} a `glideRecord` seam
 */
function glideRecordSeam(tables) {
    return function (name) {
        if (!tables[name]) {
            throw new Error('unexpected table access: ' + name);
        }
        return tables[name].newRecord();
    };
}

/**
 * Scripted RESTMessageV2 stand-in.
 *
 * @param {object} script
 * @param {number} [script.status]
 * @param {string} [script.body]
 * @param {Error}  [script.throwOnExecute] thrown from execute()
 * @param {string} [script.transportError]  makes haveError() true
 * @param {boolean} [script.omitErrorApi]   drop haveError/getErrorMessage entirely
 * @param {Error}  [script.haveErrorThrows] haveError() raises
 * @param {Error}  [script.errorMessageThrows] getErrorMessage() raises while
 *   haveError() still reports true — the round-1 gate finding-4 state, which the
 *   old mock had no way to produce
 * @param {Error}  [script.getBodyThrows]  getBody() raises
 */
function fakeRestMessage(script) {
    var calls = {
        headers: {},
        body: null,
        endpoint: null,
        method: null,
        timeout: null,
        constructedWith: null
    };

    var msg = {
        calls: calls,
        setHttpMethod: function (m) { calls.method = m; },
        setEndpoint: function (e) { calls.endpoint = e; },
        setRequestHeader: function (k, v) { calls.headers[k] = v; },
        setHttpTimeout: function (t) { calls.timeout = t; },
        setRequestBody: function (b) { calls.body = b; },
        execute: function () {
            if (script.throwOnExecute) { throw script.throwOnExecute; }
            var resp = {
                getStatusCode: function () { return script.status; },
                getBody: function () {
                    if (script.getBodyThrows) { throw script.getBodyThrows; }
                    return script.body;
                }
            };
            if (!script.omitErrorApi) {
                resp.haveError = function () {
                    if (script.haveErrorThrows) { throw script.haveErrorThrows; }
                    return !!script.transportError || !!script.errorMessageThrows;
                };
                resp.getErrorMessage = function () {
                    if (script.errorMessageThrows) { throw script.errorMessageThrows; }
                    return script.transportError || '';
                };
                resp.getErrorCode = function () { return script.transportError ? '1' : '0'; };
            }
            return resp;
        }
    };
    return msg;
}

module.exports = {
    FakeTable: FakeTable,
    glideRecordSeam: glideRecordSeam,
    fakeRestMessage: fakeRestMessage
};
