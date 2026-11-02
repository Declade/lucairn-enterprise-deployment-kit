// The companion job: one tick. Logs ONE line, and only for two results: built, or failed with its reason word.
(function() {
    try {
        var r = new x_1620539_lucdir.LucairnCompanionPublisher().runScheduled();
        if (r && r.result === 'built') gs.info('Lucairn companion: built');
        else if (r && r.result === 'failed')
            gs.info('Lucairn companion: failed, ' + (/^[a-z_]+(:[a-z0-9_]+)?$/.test(String(r.reason)) ? String(r.reason) : 'unexpected'));
    } catch (e) {
        gs.info('Lucairn companion: tick error');
    }
})();
