import {Component, Input, OnInit, ViewChild, TemplateRef, EventEmitter} from '@angular/core';
import {Observable, Observer} from 'rxjs';
import {NgbModal, NgbModalRef, NgbModalOptions} from '@ng-bootstrap/ng-bootstrap';

/**
 * Dialog base class.  Handles the ngbModal logic.
 * Sub-classed component templates must have a #dialogContent selector
 * at the root of the template (see ConfirmDialogComponent).
 *
 * Dialogs interact with the caller via Observable.
 *
 * dialog.open().subscribe(
 *   value => handleValue(value),
 *   error => handleError(error),
 *   ()    => console.debug('dialog closed')
 * );
 *
 * It is up to the dialog implementer to decide what values to
 * pass to the caller via the dialog.respond(data) and/or
 * dialog.close(data) methods.
 *
 * dialog.close(...) closes the modal window and completes the
 * observable, unless an error was previously passed, in which
 * case the observable is already complete.
 *
 * dialog.close() with no data closes the dialog without passing
 * any values to the caller.
 */

@Component({
    selector: 'eg-dialog',
    template: '<ng-template></ng-template>'
})
export class DialogComponent implements OnInit {

    // Track instances so we can refer to them later in closeAll()
    // NOTE this could also be done by importing router and subscribing
    // to route events here, but that would require all subclassed
    // components to import and pass the router via the constructor.
    static counter = 0;
    static instances: {[ident: number]: any} = {};

    // Assume all dialogs support a title attribute.
    @Input() public dialogTitle: string;

    // Pointer to the dialog content template.
    @ViewChild('dialogContent', {static: false})
    private dialogContent: TemplateRef<any>;

    identifier: number = DialogComponent.counter++;

    // Emitted after open() is called on the ngbModal.
    // Note when overriding open(), this will not fire unless also
    // called in the overridding method.
    onOpen$ = new EventEmitter<any>();

    // How we relay responses to the caller.
    observer: Observer<any>;

    // The modalRef allows direct control of the modal instance.
    private modalRef: NgbModalRef = null;

    constructor(private modalService: NgbModal) {}

    // Close all active dialogs
    static closeAll() {
        Object.keys(DialogComponent.instances).forEach(id => {
            if (DialogComponent.instances[id]) {
                DialogComponent.instances[id].close();
                delete DialogComponent.instances[id];
            }
        });
    }

    ngOnInit() {
        this.onOpen$ = new EventEmitter<any>();
    }

    open(options: NgbModalOptions = { backdrop: 'static' }): Observable<any> {

        if (this.modalRef !== null) {
            this.error('Dialog was replaced!');
            this.finalize();
        }

        // force backdrop to static if caller passed in any options
        options.backdrop = 'static';

        this.modalRef = this.modalService.open(this.dialogContent, options);
        DialogComponent.instances[this.identifier] = this;

        if (this.onOpen$) {
            // Let the digest cycle complete
            setTimeout(() => this.onOpen$.emit(true));
        }

        return new Observable(observer => {
            this.observer = observer;

            this.modalRef.result.then(
                // Results are relayed to the caller via our observer.
                // Our Observer is marked complete via this.close().
                // Nothing to do here.
                result => {},

                // Modal was dismissed via UI control which
                // bypasses call to this.close()
                dismissed => this.finalize()
            );
        });
    }

    // Send a response to the caller without closing the dialog.
    respond(value: any) {
        if (this.observer && value !== undefined) {
            this.observer.next(value);
        }
    }

    // Sends error event to the caller and closes the dialog.
    // Once an error is sent, our observable is complete and
    // cannot be used again to send any messages.
    error(value: any, close?: boolean) {
        if (this.observer) {
            console.error('Dialog produced error', value);
            this.observer.error(value);
            this.observer = null;
        }
        if (this.modalRef) { this.modalRef.close(); }
        this.finalize();
    }

    // Close the dialog, optionally with a value to relay to the caller.
    // Calling close() with no value simply dismisses the dialog.
    close(value?: any) {
        this.respond(value);
        if (this.modalRef) { this.modalRef.close(); }
        this.finalize();
    }

    dismiss() {
        console.warn('Dialog.dismiss() is deprecated.  Use close() instead');
        this.close();
    }

    // Clean up after closing the dialog.
    finalize() {
        if (this.observer) { // null if this.error() called
            this.observer.complete();
            this.observer = null;
        }
        this.modalRef = null;
        delete DialogComponent.instances[this.identifier];
    }

}


