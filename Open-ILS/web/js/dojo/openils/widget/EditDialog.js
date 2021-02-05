/**
var dialog = new openils.widget.EditDialog({
    fmObject: survey,
    fieldOrder: ['id', 'name', 'description', 'start_date', 'end_date']
});
dialog.startup();
dialog.show();
*/



if(!dojo._hasResource['openils.widget.EditDialog']) {
    dojo.provide('openils.widget.EditDialog');
    dojo.require('openils.widget.EditPane');
    dojo.require('dijit.Dialog');
    dojo.require('openils.Util');

    /**
     * Given a fieldmapper object, this builds a pop-up dialog used for editing the object
     */

    dojo.declare(
        'openils.widget.EditDialog',
        [dijit.Dialog],
        {
            editPane : null, // reference to our EditPane object

            constructor : function(args) {
                args = args || {};
                this.editPane = args.editPane || new openils.widget.EditPane(args);
                var self = this;

                var onCancel = args.onCancel || this.editPane.onCancel;
                var onSubmit = args.onPostSubmit || this.editPane.onPostSubmit;

                this.editPane.onCancel = function() { 
                    if(onCancel) onCancel();
                    self.hide(); 
                }

                this.editPane.onPostSubmit = function(r, cudResults) { 
                    self.hide(); 
                    if(onSubmit) onSubmit(r, cudResults);
                }
            },

            /**
             * Builds a basic table of key / value pairs.  Keys are IDL display labels.
             * Values are dijit's, when values set
             */
            startup : function() {
                this.inherited(arguments);
                this.attr('content', this.editPane);
                openils.Util.addCSSClass(this.editPane.table, 'oils-fm-edit-dialog');
            }
        }
    );
}

