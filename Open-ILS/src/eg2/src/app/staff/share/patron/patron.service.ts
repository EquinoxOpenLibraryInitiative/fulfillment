import {Injectable} from '@angular/core';
import {IdlObject} from '@eg/core/idl.service';
import {NetService} from '@eg/core/net.service';
import {EventService} from '@eg/core/event.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {AuthService} from '@eg/core/auth.service';
import {Observable} from 'rxjs';


@Injectable()
export class PatronService {
    constructor(
        private net: NetService,
        private evt: EventService,
        private pcrud: PcrudService,
        private auth: AuthService
    ) {}

    bcSearch(barcode: string): Observable<any> {
        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.get_barcodes',
            this.auth.token(), this.auth.user().ws_ou(),
           'actor', barcode.trim());
    }

    getByBarcode(barcode: string, pcrudOps?: any): Promise<IdlObject> {
        return this.bcSearch(barcode).toPromise()
        .then(barcodes => {

            // Use the first successful barcode response.
            // TODO: What happens when there are multiple responses?
            // Use for-loop for early exit since we have async
            // action within the loop.
            for (let i = 0; i < barcodes.length; i++) {
                const bc = barcodes[i];
                if (!this.evt.parse(bc)) {
                    return this.getById(bc.id);
                }
            }

            return null;
        });
    }

    getById(id: number, pcrudOps?: any): Promise<IdlObject> {
        return this.pcrud.retrieve('au', id, pcrudOps).toPromise();
    }

}

