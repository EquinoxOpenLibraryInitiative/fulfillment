import {Component, OnInit, Input, ViewChild, ViewEncapsulation
    } from '@angular/core';
import {Router} from '@angular/router';
import {Observable, Observer, of} from 'rxjs';
import {map} from 'rxjs/operators';
import {Pager} from '@eg/share/util/pager';
import {IdlObject, IdlService} from '@eg/core/idl.service';
import {OrgService} from '@eg/core/org.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {AuthService} from '@eg/core/auth.service';
import {NetService} from '@eg/core/net.service';
import {GridDataSource} from '@eg/share/grid/grid';
import {GridComponent} from '@eg/share/grid/grid.component';
import {GridToolbarCheckboxComponent
    } from '@eg/share/grid/grid-toolbar-checkbox.component';
import {StoreService} from '@eg/core/store.service';
import {ServerStoreService} from '@eg/core/server-store.service';
import {ToastService} from '@eg/share/toast/toast.service';

import {EditOuSettingDialogComponent
    } from '@eg/staff/admin/local/org-unit-settings/edit-org-unit-setting-dialog.component';
import {OuSettingHistoryDialogComponent
    } from '@eg/staff/admin/local/org-unit-settings/org-unit-setting-history-dialog.component';
import {OuSettingJsonDialogComponent
    } from '@eg/staff/admin/local/org-unit-settings/org-unit-setting-json-dialog.component';

export class OrgUnitSetting {
    name: string;
    label: string;
    grp: string;
    description: string;
    value: any;
    value_str: any;
    dataType: string;
    fmClass: string;
    _idlOptions: IdlObject[];
    _org_unit: IdlObject;
    context: string;
    view_perm: string;
    _history: any[];
}

@Component({
    templateUrl: './org-unit-settings.component.html'
})

export class OrgUnitSettingsComponent {

    contextOrg: IdlObject;

    initDone = false;
    gridDataSource: GridDataSource;
    gridTemplateContext: any;
    prevFilter: string;
    currentHistory: any[];
    currentOptions: any[];
    jsonFieldData: {};
    @ViewChild('orgUnitSettingsGrid', { static:true }) orgUnitSettingsGrid: GridComponent;

    @ViewChild('editOuSettingDialog', { static:true })
        private editOuSettingDialog: EditOuSettingDialogComponent;
    @ViewChild('orgUnitSettingHistoryDialog', { static:true })
        private orgUnitSettingHistoryDialog: OuSettingHistoryDialogComponent;
    @ViewChild('ouSettingJsonDialog', { static:true })
        private ouSettingJsonDialog: OuSettingJsonDialogComponent;

    refreshSettings: boolean;
    renderFromPrefs: boolean;

    settingTypeArr: any[];

    @Input() filterString: string;

    constructor(
        private router: Router,
        private org: OrgService,
        private idl: IdlService,
        private pcrud: PcrudService,
        private auth: AuthService,
        private store: ServerStoreService,
        private localStore: StoreService,
        private toast: ToastService,
        private net: NetService,
    ) {
        this.gridDataSource = new GridDataSource();
        this.refreshSettings = true;
        this.renderFromPrefs = true;

        this.contextOrg = this.org.get(this.auth.user().ws_ou());
    }

    ngOnInit() {
        this.initDone = true;
        this.settingTypeArr = [];
        this.gridDataSource.getRows = (pager: Pager, sort: any[]) => {
            return this.fetchSettingTypes(pager);
        };
        this.orgUnitSettingsGrid.onRowActivate.subscribe((setting:OrgUnitSetting) => {
            this.showEditSettingValueDialog(setting);
        });
    }

    fetchSettingTypes(pager: Pager): Observable<any> {
        return new Observable<any>(observer => {
            this.pcrud.retrieveAll('coust', {flesh: 3, flesh_fields: {
                'coust': ['grp', 'view_perm']
            }},
            { authoritative: true }).subscribe(
                settingTypes => this.allocateSettingTypes(settingTypes),
                err => {},
                ()  => {
                    this.refreshSettings = false;
                    this.mergeSettingValues().then(
                        ok => {
                            this.flattenSettings(observer);
                        }
                    );
                }
            );
        });
    }

    mergeSettingValues(): Promise<any> {
        const settingNames = this.settingTypeArr.map(setting => setting.name);
        return new Promise((resolve, reject) => {
            this.net.request(
                'open-ils.actor',
                'open-ils.actor.ou_setting.ancestor_default.batch',
                 this.contextOrg.id(), settingNames, this.auth.token()
            ).subscribe(
                blob => {
                    let settingVals = Object.keys(blob).map(key => {
                        return {'name': key, 'setting': blob[key]}
                    });
                    settingVals.forEach(key => {
                        if (key.setting) {
                            let settingsObj = this.settingTypeArr.filter(
                                setting => setting.name == key.name
                            )[0];
                            settingsObj.value = key.setting.value;
                            settingsObj.value_str = settingsObj.value;
                            if (settingsObj.dataType == 'link' && (key.setting.value || key.setting.value == 0)) {
                                this.fetchLinkedField(settingsObj.fmClass, key.setting.value, settingsObj.value_str).then(res => {
                                    settingsObj.value_str = res;
                                });
                            }
                            settingsObj._org_unit = this.org.get(key.setting.org);
                            settingsObj.context = settingsObj._org_unit.shortname();
                        }
                    });
                    resolve(this.settingTypeArr);
                },
                err => reject(err)
            );
        });
    }

    fetchLinkedField(fmClass, id, val) {
        return new Promise((resolve, reject) => {
            return this.pcrud.retrieve(fmClass, id).subscribe(linkedField => {
                val = linkedField.name();
                resolve(val);
            });
        });
    }

    fetchHistory(setting): Promise<any> {
        let name = setting.name;
        return new Promise((resolve, reject) => {
            this.net.request(
                'open-ils.actor',
                'open-ils.actor.org_unit.settings.history.retrieve',
                this.auth.token(), name, this.contextOrg.id()
            ).subscribe(res=> {
                this.currentHistory = [];
                if (!Array.isArray(res)) {
                    res = [res];
                }
                res.forEach(log => {
                    log.org = this.org.get(log.org);
                    log.new_value_str = log.new_value;
                    log.original_value_str = log.original_value;
                    if (setting.dataType == "link") {
                        if (log.new_value) {
                            this.fetchLinkedField(setting.fmClass, parseInt(log.new_value), log.new_value_str).then(val => {
                                log.new_value_str = val;
                            });
                        }
                        if (log.original_value) {
                            this.fetchLinkedField(setting.fmClass, parseInt(log.original_value), log.original_value_str).then(val => {
                                log.original_value_str = val;
                            });
                        }
                    }
                    if (log.new_value_str) log.new_value_str = log.new_value_str.replace(/^"(.*)"$/, '$1');
                    if (log.original_value_str) log.original_value_str = log.original_value_str.replace(/^"(.*)"$/, '$1');
                });
                this.currentHistory = res;
                this.currentHistory.sort((a, b) => {
                    return a.date_applied < b.date_applied ? 1 : -1;
                });

                resolve(this.currentHistory);
            }, err=>{reject(err);});
        });
    }

    allocateSettingTypes(coust: IdlObject) {
        let entry = new OrgUnitSetting();
        entry.name = coust.name();
        entry.label = coust.label();
        entry.dataType = coust.datatype();
        if (coust.fm_class()) entry.fmClass = coust.fm_class();
        if (coust.description()) entry.description = coust.description();
        // For some reason some setting types don't have a grp, should look into this...
        if (coust.grp()) entry.grp = coust.grp().label();
        if (coust.view_perm()) 
            entry.view_perm = coust.view_perm().code();

        this.settingTypeArr.push(entry);
    }

    flattenSettings(observer: Observer<any>) {
        this.gridDataSource.data = this.settingTypeArr;
        observer.complete();
    }

    contextOrgChanged(org: IdlObject) {
        this.updateGrid(org);
    }

    applyFilter(clear?: boolean) {
        if (clear) this.filterString = '';
        this.updateGrid(this.contextOrg);
    }
    
    updateSetting(obj, entry) {
        this.net.request(
            'open-ils.actor',
            'open-ils.actor.org_unit.settings.update',
            this.auth.token(), obj.context.id(), obj.setting
        ).toPromise().then(res=> {
            this.toast.success(entry.label + " Updated.");
            if (!obj.setting[entry.name]) {
                let settingsObj = this.settingTypeArr.filter(
                    setting => setting.name == entry.name
                )[0];
                settingsObj.value = null;
                settingsObj.value_str = null;
                settingsObj._org_unit = null;
                settingsObj.context = null;
            }
            this.mergeSettingValues();
        },
        err => {
            this.toast.danger(entry.label + " failed to update: " + err.desc);
        });
    }

    showEditSettingValueDialog(entry: OrgUnitSetting) {
        this.editOuSettingDialog.entry = entry;
        this.editOuSettingDialog.entryValue = entry.value;
        this.editOuSettingDialog.entryContext = entry._org_unit || this.contextOrg;
        this.editOuSettingDialog.open({size: 'lg'}).subscribe(
            res => {
                this.updateSetting(res, entry);
            }
        );
    }

    showHistoryDialog(entry: OrgUnitSetting) {
        if (entry) {
            this.fetchHistory(entry).then(
                fetched => {
                    this.orgUnitSettingHistoryDialog.history = this.currentHistory;
                    this.orgUnitSettingHistoryDialog.gridDataSource.data = this.currentHistory;
                    this.orgUnitSettingHistoryDialog.entry = entry;
                    this.orgUnitSettingHistoryDialog.open({size: 'lg'}).subscribe(res => {
                        if (res.revert) {
                            this.updateSetting(res, entry);
                        }
                    });
                }
            )
        }
    }

    showJsonDialog(isExport: boolean) {
        this.ouSettingJsonDialog.isExport = isExport;
        this.ouSettingJsonDialog.jsonData = "";
        if (isExport) {
            this.ouSettingJsonDialog.jsonData = "{";
            this.gridDataSource.data.forEach(entry => {
                this.ouSettingJsonDialog.jsonData +=
                    "\"" + entry.name + "\": {\"org\": \"" +
                    this.contextOrg.id() + "\", \"value\": ";
                if (entry.value) {
                    this.ouSettingJsonDialog.jsonData += "\"" + entry.value + "\"";
                } else {
                    this.ouSettingJsonDialog.jsonData += "null";
                }
                this.ouSettingJsonDialog.jsonData += "}";
                if (this.gridDataSource.data.indexOf(entry) != (this.gridDataSource.data.length - 1))
                    this.ouSettingJsonDialog.jsonData += ",";
            });
            this.ouSettingJsonDialog.jsonData += "}";
        }

        this.ouSettingJsonDialog.open({size: 'lg'}).subscribe(res => {
            if (res.apply && res.jsonData) {
                let jsonSettings = JSON.parse(res.jsonData);
                Object.entries(jsonSettings).forEach((fields) => {
                    let entry = this.settingTypeArr.find(x => x.name == fields[0]);
                    let obj = {setting: {}, context: {}};
                    let val = this.parseValType(fields[1]['value'], entry.dataType);
                    obj.setting[fields[0]] = val;
                    obj.context = this.org.get(fields[1]['org']);
                    this.updateSetting(obj, entry);
                });
            }
        });
    }

    parseValType(value, dataType) {
        if (dataType == "integer" || "currency" || "link") {
            return Number(value);
        } else if (dataType == "bool") {
            return (value === 'true');
        } else {
            return value;
        }
    }
    
    filterCoust() {
        if (this.filterString != this.prevFilter) {
            this.prevFilter = this.filterString;
            if (this.filterString) {
                this.gridDataSource.data = [];
                let tempGrid = this.settingTypeArr;
                tempGrid.forEach(row => {
                    let containsString =
                         row.name.includes(this.filterString) ||
                         row.label.includes(this.filterString) ||
                         (row.grp && row.grp.includes(this.filterString)) ||
                         (row.description && row.description.includes(this.filterString));
                    if (containsString) {
                        this.gridDataSource.data.push(row);
                    }
                });
            } else {
                this.gridDataSource.data = this.settingTypeArr;
            }
        }
    }

    updateGrid(org) {
        if (this.contextOrg != org) {
            this.contextOrg = org;
            this.refreshSettings = true;
        }

        if (this.filterString != this.prevFilter) {
            this.refreshSettings = true;
        }

        if (this.refreshSettings) { 
            this.mergeSettingValues().then(
                res => this.filterCoust()
            );
        }
    }
}
