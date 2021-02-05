dojo.require('dojox.grid.DataGrid');
dojo.require('dojo.data.ItemFileWriteStore');
dojo.require('dojox.form.CheckedMultiSelect');
dojo.require('dijit.form.TextBox');
dojo.require('dojox.grid.cells.dijit');
dojo.require('openils.widget.AutoGrid');

 var spCache = {};

function spBuildGrid() {
    spGrid.disableWidgetTest = function(field, obj) {
        if(obj && obj.id() < 100 && field == 'name')
            return true;
        return false;
    }
    spGrid.loadAll({order_by:{csp : 'name'}});
}

function formatId(inDatum) {
    if(inDatum < 100){
        return "<span style='color:red;'>"+ inDatum +"</span>";
    }
    return inDatum;
}

openils.Util.addOnLoad(spBuildGrid);


