import {Injectable} from '@angular/core';
import {Observable, empty, from} from 'rxjs';
import {map, concatMap, mergeMap} from 'rxjs/operators';
import {IdlObject} from '@eg/core/idl.service';
import {NetService} from '@eg/core/net.service';
import {OrgService} from '@eg/core/org.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {EventService, EgEvent} from '@eg/core/event.service';
import {AuthService} from '@eg/core/auth.service';
import {BibRecordService, BibRecordSummary} from '@eg/share/catalog/bib-record.service';
import {AudioService} from '@eg/share/util/audio.service';
import {CircEventsComponent} from './events-dialog.component';
import {CircComponentsComponent} from './components.component';
import {StringService} from '@eg/share/string/string.service';
import {ServerStoreService} from '@eg/core/server-store.service';

export interface CircDisplayInfo {
    title?: string;
    author?: string;
    isbn?: string;
    copy?: IdlObject;        // acp
    volume?: IdlObject;      // acn
    record?: IdlObject;      // bre
    display?: IdlObject;     // mwde
}

const CAN_OVERRIDE_CHECKOUT_EVENTS = [
    'PATRON_EXCEEDS_OVERDUE_COUNT',
    'PATRON_EXCEEDS_CHECKOUT_COUNT',
    'PATRON_EXCEEDS_FINES',
    'PATRON_EXCEEDS_LONGOVERDUE_COUNT',
    'PATRON_BARRED',
    'CIRC_EXCEEDS_COPY_RANGE',
    'ITEM_DEPOSIT_REQUIRED',
    'ITEM_RENTAL_FEE_REQUIRED',
    'PATRON_EXCEEDS_LOST_COUNT',
    'COPY_CIRC_NOT_ALLOWED',
    'COPY_NOT_AVAILABLE',
    'COPY_IS_REFERENCE',
    'COPY_ALERT_MESSAGE',
    'ITEM_ON_HOLDS_SHELF',
    'STAFF_C',
    'STAFF_CH',
    'STAFF_CHR',
    'STAFF_CR',
    'STAFF_H',
    'STAFF_HR',
    'STAFF_R'
];

const CHECKOUT_OVERRIDE_AFTER_FIRST = [
    'PATRON_EXCEEDS_OVERDUE_COUNT',
    'PATRON_BARRED',
    'PATRON_EXCEEDS_LOST_COUNT',
    'PATRON_EXCEEDS_CHECKOUT_COUNT',
    'PATRON_EXCEEDS_FINES',
    'PATRON_EXCEEDS_LONGOVERDUE_COUNT'
];

const CAN_OVERRIDE_RENEW_EVENTS = [
    'PATRON_EXCEEDS_OVERDUE_COUNT',
    'PATRON_EXCEEDS_LOST_COUNT',
    'PATRON_EXCEEDS_CHECKOUT_COUNT',
    'PATRON_EXCEEDS_FINES',
    'PATRON_EXCEEDS_LONGOVERDUE_COUNT',
    'CIRC_EXCEEDS_COPY_RANGE',
    'ITEM_DEPOSIT_REQUIRED',
    'ITEM_RENTAL_FEE_REQUIRED',
    'ITEM_DEPOSIT_PAID',
    'COPY_CIRC_NOT_ALLOWED',
    'COPY_NOT_AVAILABLE',
    'COPY_IS_REFERENCE',
    'COPY_ALERT_MESSAGE',
    'COPY_NEEDED_FOR_HOLD',
    'MAX_RENEWALS_REACHED',
    'CIRC_CLAIMS_RETURNED',
    'STAFF_C',
    'STAFF_CH',
    'STAFF_CHR',
    'STAFF_CR',
    'STAFF_H',
    'STAFF_HR',
    'STAFF_R'
];

// These checkin events do not produce alerts when
// options.suppress_alerts is in effect.
const CAN_SUPPRESS_CHECKIN_ALERTS = [
    'COPY_BAD_STATUS',
    'PATRON_BARRED',
    'PATRON_INACTIVE',
    'PATRON_ACCOUNT_EXPIRED',
    'ITEM_DEPOSIT_PAID',
    'CIRC_CLAIMS_RETURNED',
    'COPY_ALERT_MESSAGE',
    'COPY_STATUS_LOST',
    'COPY_STATUS_LOST_AND_PAID',
    'COPY_STATUS_LONG_OVERDUE',
    'COPY_STATUS_MISSING',
    'PATRON_EXCEEDS_FINES'
];

const CAN_OVERRIDE_CHECKIN_ALERTS = [
    // not technically overridable, but special prompt and param
    'HOLD_CAPTURE_DELAYED',
    'TRANSIT_CHECKIN_INTERVAL_BLOCK'
].concat(CAN_SUPPRESS_CHECKIN_ALERTS);


// API parameter options
export interface CheckoutParams {
    patron_id?: number;
    due_date?: string;
    copy_id?: number;
    copy_barcode?: string;
    noncat?: boolean;
    noncat_type?: number;
    noncat_count?: number;
    noop?: boolean;
    precat?: boolean;
    dummy_title?: string;
    dummy_author?: string;
    dummy_isbn?: string;
    circ_modifier?: string;
    void_overdues?: boolean;

    // internal tracking
    _override?: boolean;
    _renewal?: boolean;
}

export interface CheckoutResult {
    index: number;
    firstEvent: EgEvent;
    allEvents: EgEvent[];
    params: CheckoutParams;
    success: boolean;
    canceled?: boolean;
    copy?: IdlObject;
    circ?: IdlObject;
    nonCatCirc?: IdlObject;
    record?: IdlObject;
}

export interface CheckinParams {
    noop?: boolean;
    copy_id?: number;
    copy_barcode?: string;
    claims_never_checked_out?: boolean;
    void_overdues?: boolean;
    auto_print_hold_transits?: boolean;

    // internal tracking
    _override?: boolean;
}

export interface CheckinResult {
    index: number;
    firstEvent: EgEvent;
    allEvents: EgEvent[];
    params: CheckinParams;
    success: boolean;
    copy?: IdlObject;
    volume?: IdlObject;
    circ?: IdlObject;
    record?: IdlObject;
    hold?: IdlObject;
    transit?: IdlObject;
    org?: number;
    patron?: IdlObject;
}

@Injectable()
export class CircService {
    static resultIndex = 0;

    components: CircComponentsComponent;
    nonCatTypes: IdlObject[] = null;
    autoOverrideCheckoutEvents: {[textcode: string]: boolean} = {};
    suppressCheckinPopups = false;
    ignoreCheckinPrecats = false;
    copyLocationCache: {[id: number]: IdlObject} = {};
    clearHoldsOnCheckout = false;
    orgAddrCache: {[addrId: number]: IdlObject} = {};

    constructor(
        private audio: AudioService,
        private evt: EventService,
        private org: OrgService,
        private net: NetService,
        private pcrud: PcrudService,
        private serverStore: ServerStoreService,
        private strings: StringService,
        private auth: AuthService,
        private bib: BibRecordService,
    ) {}

    applySettings(): Promise<any> {
        return this.serverStore.getItemBatch([
            'circ.clear_hold_on_checkout',
        ]).then(sets => {
            this.clearHoldsOnCheckout = sets['circ.clear_hold_on_checkout'];
        });
    }

    // 'circ' is fleshed with copy, vol, bib, wide_display_entry
    // Extracts some display info from a fleshed circ.
    getDisplayInfo(circ: IdlObject): CircDisplayInfo {

        const copy = circ.target_copy();

        if (copy.call_number().id() === -1) { // precat
            return {
                title: copy.dummy_title(),
                author: copy.dummy_author(),
                isbn: copy.dummy_isbn(),
                copy: copy
            };
        }

        const volume = copy.call_number();
        const record = volume.record();
        const display = record.wide_display_entry();

        let isbn = JSON.parse(display.isbn());
        if (Array.isArray(isbn)) { isbn = isbn.join(','); }

        return {
            title: JSON.parse(display.title()),
            author: JSON.parse(display.author()),
            isbn: isbn,
            copy: copy,
            volume: volume,
            record: record,
            display: display
        };
    }

    getOrgAddr(orgId: number, addrType): Promise<IdlObject> {
        const org = this.org.get(orgId);
        const addrId = this.org[addrType]();

        if (!addrId) { return Promise.resolve(null); }

        if (this.orgAddrCache[addrId]) {
            return Promise.resolve(this.orgAddrCache[addrId]);
        }

        return this.pcrud.retrieve('aoa', addrId).toPromise()
        .then(addr => {
            this.orgAddrCache[addrId] = addr;
            return addr;
        });
    }

    // find the open transit for the given copy barcode; flesh the org
    // units locally.
    findCopyTransit(result: CheckinResult): Promise<IdlObject> {
        // NOTE: evt.payload.transit may exist, but it's not necessarily
        // the transit we want, since a transit close + open in the API
        // returns the closed transit.

         return this.pcrud.search('atc',
            {   dest_recv_time : null, cancel_time : null},
            {   flesh : 1,
                flesh_fields : {atc : ['target_copy']},
                join : {
                    acp : {
                        filter : {
                            barcode : result.params.copy_barcode,
                            deleted : 'f'
                        }
                    }
                },
                limit : 1,
                order_by : {atc : 'source_send_time desc'},
            }, {authoritative : true}
        ).toPromise().then(transit => {
            transit.source(this.org.get(transit.source()));
            transit.dest(this.org.get(transit.dest()));
            return transit;
        });
    }

    getNonCatTypes(): Promise<IdlObject[]> {

        if (this.nonCatTypes) {
            return Promise.resolve(this.nonCatTypes);
        }

        return this.pcrud.search('cnct',
            {owning_lib: this.org.fullPath(this.auth.user().ws_ou(), true)},
            {order_by: {cnct: 'name'}},
            {atomic: true}
        ).toPromise().then(types => this.nonCatTypes = types);
    }

    // Remove internal tracking variables on Param objects so they are
    // not sent to the server, which can result in autoload errors.
    apiParams(
        params: CheckoutParams | CheckinParams): CheckoutParams | CheckinParams {

        const apiParams = Object.assign({}, params); // clone
        const remove = Object.keys(apiParams).filter(k => k.match(/^_/));
        remove.forEach(p => delete apiParams[p]);

        return apiParams;
    }

    checkout(params: CheckoutParams): Promise<CheckoutResult> {

        params._renewal = false;
        console.debug('checking out with', params);

        let method = 'open-ils.circ.checkout.full';
        if (params._override) { method += '.override'; }

        return this.net.request(
            'open-ils.circ', method,
            this.auth.token(), this.apiParams(params)).toPromise()
        .then(result => this.processCheckoutResult(params, result));
    }

    renew(params: CheckoutParams): Promise<CheckoutResult> {

        params._renewal = true;
        console.debug('renewing out with', params);

        let method = 'open-ils.circ.renew';
        if (params._override) { method += '.override'; }

        return this.net.request(
            'open-ils.circ', method,
            this.auth.token(), this.apiParams(params)).toPromise()
        .then(result => this.processCheckoutResult(params, result));
    }

    processCheckoutResult(
        params: CheckoutParams, response: any): Promise<CheckoutResult> {


        const allEvents = Array.isArray(response) ?
            response.map(r => this.evt.parse(r)) :
            [this.evt.parse(response)];

        console.debug('checkout returned', allEvents.map(e => e.textcode));

        const firstEvent = allEvents[0];
        const payload = firstEvent.payload;

        if (!payload) {
            this.audio.play('error.unknown.no_payload');
            return Promise.reject();
        }

        const result: CheckoutResult = {
            index: CircService.resultIndex++,
            firstEvent: firstEvent,
            allEvents: allEvents,
            params: params,
            success: false,
            circ: payload.circ,
            copy: payload.copy,
            record: payload.record,
            nonCatCirc: payload.noncat_circ
        };

        const overridable = result.params._renewal ?
            CAN_OVERRIDE_RENEW_EVENTS : CAN_OVERRIDE_CHECKOUT_EVENTS;

        if (allEvents.filter(
            e => overridable.includes(e.textcode)).length > 0) {
            return this.handleOverridableCheckoutEvents(result, allEvents);
        }

        switch (firstEvent.textcode) {
            case 'SUCCESS':
                result.success = true;
                this.audio.play('success.checkout');
                break;

            case 'ITEM_NOT_CATALOGED':
                return this.handlePrecat(result);

            case 'OPEN_CIRCULATION_EXISTS':
                return this.handleOpenCirc(result);
        }

        return Promise.resolve(result);
    }


    // Ask the user if we should resolve the circulation and check
    // out to the user or leave it alone.
    // When resolving and checking out, renew if it's for the same
    // user, otherwise check it in, then back out to the current user.
    handleOpenCirc(result: CheckoutResult): Promise<CheckoutResult> {

        let sameUser = false;

        return this.net.request(
            'open-ils.circ',
            'open-ils.circ.copy_checkout_history.retrieve',
            this.auth.token(), result.params.copy_id, 1).toPromise()

        .then(circs => {
            const circ = circs[0];

            sameUser = result.params.patron_id === circ.usr();
            this.components.openCircDialog.sameUser = sameUser;
            this.components.openCircDialog.circDate = circ.xact_start();

            return this.components.openCircDialog.open().toPromise();
        })

        .then(fromDialog => {

            // Leave the open circ checked out.
            if (!fromDialog) { return result; }

            const coParams = Object.assign({}, result.params); // clone

            if (sameUser) {
                coParams.void_overdues = fromDialog.forgiveFines;
                return this.renew(coParams);
            }

            const ciParams: CheckinParams = {
                noop: true,
                copy_id: coParams.copy_id,
                void_overdues: fromDialog.forgiveFines
            };

            return this.checkin(ciParams)
            .then(res => {
                if (res.success) {
                    return this.checkout(coParams);
                } else {
                    return Promise.reject('Unable to check in item');
                }
            });
        });
    }

    handleOverridableCheckoutEvents(
        result: CheckoutResult, events: EgEvent[]): Promise<CheckoutResult> {
        const params = result.params;
        const firstEvent = events[0];

        if (params._override) {
            // Should never get here.  Just being safe.
            return Promise.reject(null);
        }

        if (events.filter(
            e => !this.autoOverrideCheckoutEvents[e.textcode]).length === 0) {
            // User has already seen all of these events and overridden them,
            // so avoid showing them again since they are all auto-overridable.
            params._override = true;
            return params._renewal ? this.renew(params) : this.checkout(params);
        }

        return this.showOverrideDialog(result, events);
    }

    showOverrideDialog(result: CheckoutResult,
        events: EgEvent[], checkin?: boolean): Promise<CheckoutResult> {

        const params = result.params;
        const mode = checkin ? 'checkin' : (params._renewal ? 'renew' : 'checkout');

        this.components.circEventsDialog.events = events;
        this.components.circEventsDialog.mode = mode;

        return this.components.circEventsDialog.open().toPromise()
        .then(confirmed => {
            if (!confirmed) { return null; }

            if (!checkin) {
                // Indicate these events have been seen and overridden.
                events.forEach(evt => {
                    if (CHECKOUT_OVERRIDE_AFTER_FIRST.includes(evt.textcode)) {
                        this.autoOverrideCheckoutEvents[evt.textcode] = true;
                    }
                });
            }

            params._override = true;

            return this[mode](params); // checkout/renew/checkin
        });
    }

    handlePrecat(result: CheckoutResult): Promise<CheckoutResult> {
        this.components.precatDialog.barcode = result.params.copy_barcode;

        return this.components.precatDialog.open().toPromise().then(values => {

            if (values && values.dummy_title) {
                const params = result.params;
                params.precat = true;
                Object.keys(values).forEach(key => params[key] = values[key]);
                return this.checkout(params);
            }

            result.canceled = true;
            return Promise.resolve(result);
        });
    }

    checkin(params: CheckinParams): Promise<CheckinResult> {

        console.debug('checking in with', params);

        let method = 'open-ils.circ.checkin';
        if (params._override) { method += '.override'; }

        return this.net.request(
            'open-ils.circ', method,
            this.auth.token(), this.apiParams(params)).toPromise()
        .then(result => this.unpackCheckinData(params, result))
        .then(result => this.processCheckinResult(result));
    }

    unpackCheckinData(params: CheckinParams, response: any): Promise<CheckinResult> {
        const allEvents = Array.isArray(response) ?
            response.map(r => this.evt.parse(r)) : [this.evt.parse(response)];

        console.debug('checkin returned', allEvents.map(e => e.textcode));

        const firstEvent = allEvents[0];
        const payload = firstEvent.payload;

        if (!payload) {
            this.audio.play('error.unknown.no_payload');
            return Promise.reject();
        }

        const success =
            firstEvent.textcode.match(/SUCCESS|NO_CHANGE|ROUTE_ITEM/) !== null;

        const result: CheckinResult = {
            index: CircService.resultIndex++,
            firstEvent: firstEvent,
            allEvents: allEvents,
            params: params,
            success: success,
            circ: payload.circ,
            copy: payload.copy,
            volume: payload.volume,
            record: payload.record,
            transit: payload.transit
        };

        let promise = Promise.resolve();;
        const copy = result.copy;
        const volume = result.volume;

        if (copy) {
            if (this.copyLocationCache[copy.location()]) {
                copy.location(this.copyLocationCache[copy.location()]);
            } else {
                promise = this.pcrud.retrieve('acpl', copy.location()).toPromise()
                .then(loc => {
                    copy.location(loc);
                    this.copyLocationCache[loc.id()] = loc;
                });
            }
        }

        if (volume) {
            // Flesh volume prefixes and suffixes

            if (typeof volume.prefix() !== 'object') {
                promise = promise.then(_ =>
                    this.pcrud.retrieve('acnp', volume.prefix()).toPromise()
                ).then(p => volume.prefix(p));
            }

            if (typeof volume.suffix() !== 'object') {
                promise = promise.then(_ =>
                    this.pcrud.retrieve('acns', volume.suffix()).toPromise()
                ).then(p => volume.suffix(p));
            }
        }

        return promise.then(_ => result);
    }

    processCheckinResult(result: CheckinResult): Promise<CheckinResult> {
        const params = result.params;
        const allEvents = result.allEvents;

        // Informational alerts that can be ignored if configured.
        if (this.suppressCheckinPopups &&
            allEvents.filter(e =>
                !CAN_SUPPRESS_CHECKIN_ALERTS.includes(e.textcode)).length === 0) {

            // Should not be necessary, but good to be safe.
            if (params._override) { return Promise.resolve(null); }

            params._override = true;
            return this.checkin(params);
        }


        // Alerts that require a manual override.
        if (allEvents.filter(
            e => CAN_OVERRIDE_CHECKIN_ALERTS.includes(e.textcode)).length > 0) {

            // Should not be necessary, but good to be safe.
            if (params._override) { return Promise.resolve(null); }

            return this.showOverrideDialog(result, allEvents, true);
        }

        switch (result.firstEvent.textcode) {
            case 'SUCCESS':
            case 'NO_CHANGE':
                return this.handleCheckinSuccess(result);

            case 'ITEM_NOT_CATALOGED':
                this.audio.play('error.checkout.no_cataloged');

                if (!this.suppressCheckinPopups && !this.ignoreCheckinPrecats) {
                    // Tell the user its a precat and return the result.
                    return this.components.routeToCatalogingDialog.open()
                    .toPromise().then(_ => result);
                }
        }

        return Promise.resolve(result);
    }

    handleCheckinSuccess(result: CheckinResult): Promise<CheckinResult> {

        switch (result.copy.status()) {

            case 0: /* AVAILABLE */
            case 4: /* MISSING */
            case 7: /* RESHELVING */
                this.audio.play('success.checkin');
                return this.handleCheckinLocAlert(result);

            case 8: /* ON HOLDS SHELF */
                this.audio.play('info.checkin.holds_shelf');

                const hold = result.hold;

                if (hold) {

                    if (hold.pickup_lib() === this.auth.user().ws_ou()) {
                        this.components.routeDialog.checkin = result;
                        return this.components.routeDialog.open().toPromise()
                        .then(_ => result);

                    } else {
                        // Should not happen in practice, but to be safe.
                        this.audio.play('warning.checkin.wrong_shelf');
                    }

                } else {
                    console.warn("API Returned insufficient info on holds");
                }
        }

        return Promise.resolve(result);
    }

    handleCheckinLocAlert(result: CheckinResult): Promise<CheckinResult> {
        const copy = result.copy;

        if (this.suppressCheckinPopups
            || copy.location().checkin_alert() === 'f') {
            return Promise.resolve(result);
        }

        return this.strings.interpolate(
            'staff.circ.checkin.location.alert',
            {barcode: copy.barcode(), location: copy.location().name()}
        ).then(str => {
            this.components.locationAlertDialog.dialogBody = str;
            return this.components.locationAlertDialog.open().toPromise()
            .then(_ => result);
        });
    }

    handleOverridableCheckinEvents(
        result: CheckinResult, events: EgEvent[]): Promise<CheckinResult> {
        const params = result.params;
        const firstEvent = events[0];

        if (params._override) {
            // Should never get here.  Just being safe.
            return Promise.reject(null);
        }
    }


    // The provided params (minus the copy_id) will be used
    // for all items.
    checkoutBatch(copyIds: number[],
        params: CheckoutParams): Observable<CheckoutResult> {

        if (copyIds.length === 0) { return empty(); }

        return from(copyIds).pipe(concatMap(id => {
            const cparams = Object.assign({}, params); // clone
            cparams.copy_id = id;
            return from(this.checkout(cparams));
        }));
    }

    // The provided params (minus the copy_id) will be used
    // for all items.
    renewBatch(copyIds: number[],
        params?: CheckoutParams): Observable<CheckoutResult> {

        if (copyIds.length === 0) { return empty(); }
        if (!params) { params = {}; }

        return from(copyIds).pipe(concatMap(id => {
            const cparams = Object.assign({}, params); // clone
            cparams.copy_id = id;
            return from(this.renew(cparams));
        }));
    }

    // The provided params (minus the copy_id) will be used
    // for all items.
    checkinBatch(copyIds: number[],
        params?: CheckinParams): Observable<CheckinResult> {

        if (copyIds.length === 0) { return empty(); }
        if (!params) { params = {}; }

        return from(copyIds).pipe(concatMap(id => {
            const cparams = Object.assign({}, params); // clone
            cparams.copy_id = id;
            return from(this.checkin(cparams));
        }));
    }
}

