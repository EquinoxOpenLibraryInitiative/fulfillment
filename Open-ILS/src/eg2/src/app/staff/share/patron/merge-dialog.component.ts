import {Component, OnInit, Input, Output, ViewChild} from '@angular/core';
import {from} from 'rxjs';
import {switchMap, concatMap} from 'rxjs/operators';
import {IdlService, IdlObject} from '@eg/core/idl.service';
import {AuthService} from '@eg/core/auth.service';
import {NetService} from '@eg/core/net.service';
import {EventService} from '@eg/core/event.service';
import {NgbModal, NgbModalOptions} from '@ng-bootstrap/ng-bootstrap';
import {DialogComponent} from '@eg/share/dialog/dialog.component';
import {PatronService, PatronStats, PatronAlerts} from './patron.service';

/**
 */

const PATRON_FLESH_FIELDS = [
    'card',
    'cards',
    'settings',
    'standing_penalties',
    'addresses',
    'billing_address',
    'mailing_address',
    'waiver_entries',
    'usr_activity',
    'notes',
    'profile',
    'net_access_level',
    'ident_type',
    'ident_type2',
    'groups'
];

class MergeContext {
    patron: IdlObject;
    stats: PatronStats;
    alerts: PatronAlerts;
}

@Component({
  selector: 'eg-patron-merge-dialog',
  templateUrl: 'merge-dialog.component.html'
})

export class PatronMergeDialogComponent
    extends DialogComponent implements OnInit {

    @Input() patronIds: [number, number];

	context1: MergeContext;
	context2: MergeContext;

    leadAccount: number = null;
    loading = true;

    constructor(
        private modal: NgbModal,
        private auth: AuthService,
        private net: NetService,
        private evt: EventService,
        private patrons: PatronService
    ) { super(modal); }

    ngOnInit() {
        this.onOpen$.subscribe(_ => {
            this.loading = true;
            this.leadAccount = null;
            this.loadPatron(this.patronIds[0])
            .then(ctx => this.context1 = ctx)
            .then(_ => this.loadPatron(this.patronIds[1]))
            .then(ctx => this.context2 = ctx)
            .then(_ => this.loading = false);
        });
    }

    loadPatron(id: number): Promise<MergeContext> {
        const ctx = new MergeContext();
        return this.patrons.getFleshedById(id, PATRON_FLESH_FIELDS)
        .then(patron => ctx.patron = patron)
        .then(_ => this.patrons.getVitalStats(ctx.patron))
        .then(stats => ctx.stats = stats)
        .then(_ => this.patrons.compileAlerts(ctx.patron, ctx.stats))
        .then(alerts => ctx.alerts = alerts)
        .then(_ => ctx);
    }

    merge() {

        const subId = this.leadAccount === this.patronIds[0] ?
            this.patronIds[1] : this.patronIds[0];

        this.net.request(
            'open-ils.actor',
            'open-ils.actor.user.merge',
            this.auth.token(), this.leadAccount, [subId]
        ).subscribe(resp => {
            const evt = this.evt.parse(resp);
            if (evt) {
                console.error(evt);
                alert(evt);
                this.close(false);
            } else {
                this.close(true);
            }
        });
    }
}



