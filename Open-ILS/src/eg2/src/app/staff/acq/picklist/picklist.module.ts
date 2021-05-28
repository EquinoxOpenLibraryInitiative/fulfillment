import {NgModule} from '@angular/core';
import {StaffCommonModule} from '@eg/staff/common.module';
import {CatalogCommonModule} from '@eg/share/catalog/catalog-common.module';
import {LineitemModule} from '@eg/staff/acq/lineitem/lineitem.module';
import {HoldingsModule} from '@eg/staff/share/holdings/holdings.module';
import {PicklistRoutingModule} from './routing.module';
import {PicklistComponent} from './picklist.component';
import {PicklistSummaryComponent} from './summary.component';
import {HttpClientModule} from '@angular/common/http';
import {UploadComponent} from './upload.component';

@NgModule({
  declarations: [
    PicklistComponent,
    PicklistSummaryComponent,
    UploadComponent
  ],
  imports: [
    StaffCommonModule,
    CatalogCommonModule,
    LineitemModule,
    HoldingsModule,
    PicklistRoutingModule,
    HttpClientModule
  ],
  providers: []
})

export class PicklistModule {}