'use strict';
// Keep navigation within this application's own RHMI states when an entry mapping is stale.
module.exports = function openEntry(rhmi, uuid, state) {
    return Promise.resolve().then(() => rhmi.openEntryState(uuid)).catch(error => {
        if (!/INVALID_UUID/.test(String(error && error.message || error) + ' ' + JSON.stringify(error || {}))) throw error;
        return rhmi.openState(state);
    });
};
