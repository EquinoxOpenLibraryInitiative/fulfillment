dojo.require('dijit.layout.TabContainer');
dojo.require('dijit.form.FilteringSelect');
dojo.require('dijit.form.TextBox');
dojo.require('dojo.data.ItemFileReadStore');
dojo.require('openils.widget.AutoGrid');
dojo.require('openils.Util');
dojo.require('openils.PermaCrud');
dojo.require('openils.widget.Textarea');
dojo.require('openils.widget.ProgressDialog');
dojo.require('dojox.string.sprintf');
dojo.requireLocalization('openils.conify', 'conify');

var localeStrings = dojo.i18n.getLocalization('openils.conify', 'conify');
var eventDef = null;

function loadEventDef() { 
    eventDefGranularity.attr('value', null);
    edGrid.overrideEditWidgets.granularity = eventDefGranularity;
    edGrid.overrideEditWidgets.granularity.shove = {"create": ""};
    edGrid.loadAll({order_by:{atevdef : 'name, owner, hook, reactor, delay'}});
    openils.widget.Textarea.width = '600px';
    openils.widget.Textarea.height = '600px';
    edGrid.overrideEditWidgetClass.template = 'openils.widget.Textarea';
    edGrid.overrideEditWidgetClass.message_template = 'openils.widget.Textarea';
    dojo.connect(eventDefTabs,'selectChild', tabLoader);
}

/**
 * After an event def is cloned, see if the user wants to also clone the event def environment
 * @param {Object} oldItem Grid store item that was cloned
 * @param {Object} newObject Newly created fieldmapper object
 */
function cloneEventEnv(oldItem, newObject) {
    if(!confirm('Clone event definition environment as well?')) return; // TODO i18n
    progressDialog.show(true);
    var pcrud = new openils.PermaCrud();

    // fetch the env list for the cloned object
    var env_list = pcrud.search('atenv', {event_def : edGrid.store.getValue(oldItem, 'id')});

    if(env_list && env_list.length) {
        
        // clone the environment 
        env_list = env_list.map(
            function(item) { 
                item.id(null);
                item.event_def(newObject.id()); 
                return item; 
            }
        );
    
        // create the cloned environment list
        pcrud.create(env_list);
    }

    progressDialog.hide();
}

function loadEventDefData() { 
    var pcrud = new openils.PermaCrud();
    eventDef = pcrud.retrieve('atevdef', eventDefId);
    var hook = pcrud.retrieve('ath', eventDef.hook());

    if(hook.core_type() == 'circ') {
        openils.Util.hide('at-test-none');
        openils.Util.show('at-test-circ');
    }

    dojo.byId('at-event-def-name').innerHTML = eventDef.name();
    teeGrid.loadAll({order_by:{atenv : 'path'}}, {event_def : eventDefId}); 
    dojo.connect(eventDefTabs,'selectChild', tabLoader);

    teeGrid.overrideEditWidgets.event_def = new dijit.form.TextBox({value: eventDefId, disabled : true});
    tepGrid.overrideEditWidgets.event_def = new dijit.form.TextBox({value: eventDefId, disabled : true});
}

var loadedTabs = {'tab-atevdef' : true};
function tabLoader(child) {
    if(loadedTabs[child.id]) return;
    loadedTabs[child.id] = true;

    switch(child.id) {
        case 'tab-atevparam': 
            tepGrid.loadAll({order_by:{atevparam : 'param'}}, {event_def : eventDefId}); 
            break;
        case 'tab-ath': 
            thGrid.loadAll({order_by:{ath : 'key'}}); 
            break;
        case 'tab-atreact': 
            trGrid.loadAll({order_by:{atreact : 'module'}}); 
            break;
        case 'tab-atval': 
            tvGrid.loadAll({order_by:{atval : 'module'}}); 
            break;
        /*
        case 'tab-test': 
            loadTestTab();
            break;
        */
    }
}

function getEventDefNameLink(rowIdx, item) {
    if(!item) return
    return this.grid.store.getValue(item, 'id') + ':' + this.grid.store.getValue(item, 'name');
}

function formatEventDefNameLink(data) {
    if(!data) return;
    var parts = data.split(/:/);
    return dojox.string.sprintf(
        '<a href="%s/conify/global/action_trigger/event_definition_data/%s">%s</a>',
        oilsBasePath, parts[0], parts[1]);
}


function evtTestCirc() {
    var barcode = circTestBarcode.attr('value');
    if(!barcode) return;

    progressDialog.show();

    function handleResponse(r) {
        var evt = openils.Util.readResponse(r);
        progressDialog.hide();
        if(evt && evt != '0') {
            var output = evt.template_output();
            if(!output) output = evt.error_output();
            var pre = document.createElement('pre');
            pre.innerHTML = output.data();
            openils.Util.appendClear('test-event-output', pre);
            openils.Util.show('test-event-output');
        }
    }

    fieldmapper.standardRequest(
        ['open-ils.circ', 'open-ils.circ.trigger_event_by_def_and_barcode.fire'],
        {   async: true,
            params: [openils.User.authtoken, eventDefId, barcode],
            oncomplete: handleResponse
        }
    );
}

