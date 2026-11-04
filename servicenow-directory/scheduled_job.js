// Every run: nothing when the off switch is set or the published generation is current; else a full rebuild.
var lucairnResult = new x_1620539_lucdir.LucairnDirectoryPublisher().runScheduled();
if (lucairnResult.built || !lucairnResult.ok)
    gs.info('Lucairn directory: ' + (lucairnResult.built ? 'published generation ' + lucairnResult.generation : 'no build, ' + lucairnResult.reason));
