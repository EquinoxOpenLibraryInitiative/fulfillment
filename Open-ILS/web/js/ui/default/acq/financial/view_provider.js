dojo.require("dijit.Dialog");
dojo.require('dijit.layout.TabContainer');
dojo.require('dijit.layout.ContentPane');
dojo.require('dijit.form.FilteringSelect');
dojo.require('dojox.grid.DataGrid');
dojo.require('dojo.data.ItemFileReadStore');
dojo.require("fieldmapper.OrgUtils");
dojo.require('openils.acq.Provider');
dojo.require('openils.Event');
dojo.require('openils.User');
dojo.require('openils.Util');

var provider = null;
var marcRegex = /^\/\/\*\[@tag="(\d+)"]\/\*\[@code="(\w)"]$/;

function getOrgInfo(rowIndex, item) {
    if(!item) return ''; 
    var owner = this.grid.store.getValue(item, 'owner'); 
    return fieldmapper.aou.findOrgUnit(owner).shortname();

}

function getTag(rowIdx, item) {
    if(!item) return '';
    var xpath = this.grid.store.getValue(item, 'xpath');
    return xpath.replace(marcRegex, '$1');
}

function getSubfield(rowIdx, item) {
    if(!item) return '';
    var xpath = this.grid.store.getValue(item, 'xpath');
    return xpath.replace(marcRegex, '$2');
}

function loadProviderGrid() {
    var store = new dojo.data.ItemFileReadStore({data:acqpro.toStoreData([provider])});
   
    providerGrid.setStore(store);
    providerGrid.render();
}

function loadPADGrid() {
    openils.acq.Provider.retrieveLineitemProviderAttrDefs(providerId, 
        function(attrs) {
            var store = new dojo.data.ItemFileReadStore({data:acqlipad.toStoreData(attrs)});
            var model = new dojox.grid.data.DojoData(
                null, store, {rowsPerPage: 20, clientSort: true, query:{id:'*'}});
            padGrid.setModel(model);
            padGrid.update();
        }
    );
}


function fetchProvider() {
    fieldmapper.standardRequest(
        ['open-ils.acq', 'open-ils.acq.provider.retrieve'],
        {   async: true,
            params: [ openils.User.authtoken, providerId ],
            oncomplete: function(r) {
                provider = r.recv().content();
                loadProviderGrid(provider);
            }
        }
    );
}

function createOrderRecordField(fields) {
    fields.provider = providerId;
    if(!fields.xpath) 
        fields.xpath = '//*[@tag="'+fields.tag+'"]/*[@code="'+fields.subfield+'"]';
    delete fields.tag;
    delete fields.subfield;
    openils.acq.Provider.createLineitemProviderAttrDef(fields, 
        function(id) {
            loadPADGrid();
        }
    );
}

function setORDesc() {
    var code = dijit.byId('oils-acq-provider-or-code');
    var desc = dijit.byId('oils-acq-provider-or-desc');
    desc.setValue(code.getDisplayedValue());
}

function deleteORDataFields() {
    var list = []
    var selected = padGrid.selection.getSelected();
    for(var idx = 0; idx < selected.length; idx++) 
        list.push(padGrid.model.getRow(selected[idx]).id);
    openils.acq.Provider.lineitemProviderAttrDefDeleteList(
        list, function(){loadPADGrid();});
}


openils.Util.addOnLoad(fetchProvider);


