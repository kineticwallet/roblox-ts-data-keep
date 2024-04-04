import type { Store, StoreInfo } from "./Store";

declare interface DataKeep {
	GetStore: <D extends object>(storeInfo: StoreInfo | string, dataTemplate: D) => Promise<Store<D>>;
}

declare const DataKeep: DataKeep;

export = DataKeep;
