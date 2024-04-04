import type { Signal } from "../../lemon-signal/src/LemonSignal";
import type Keep from "./Keep";
import type { Wrapper } from "./Wrapper";

declare type ActiveSession = {
	PlaceID: number;
	JobID: number;
};

declare type StoreInfo = {
	Name: string;
	Scope?: string;
};

declare type UnReleasedActions = {
	Ignore: string;
	Cancel: string;
};

declare type UnReleasedHandler = (activeSession: ActiveSession) => keyof UnReleasedActions;

declare type GlobalID = number;

declare type GlobalUpdate = {
	Data: unknown & object;
	ID: number;
};

export declare interface GlobalUpdates {
	AddGlobalUpdate: <T extends object>(globalData: T) => Promise<GlobalID>;
	GetActiveUpdates: () => GlobalUpdate[];
	RemoveActiveUpdate: (updateId: GlobalID) => Promise<void>;
	ChangeActiveUpdate: <T extends object>(updateId: GlobalID, globalData: T) => Promise<void>;
}

declare interface Store<T extends object> {
	Wrapper: Wrapper & object;

	readonly Mock: Store<T>;
	readonly IssueSignal: Signal<unknown>;
	readonly CriticalStateSignal: Signal<void>;
	readonly CriticalState: boolean;

	validate: (data: T) => boolean | LuaTuple<[boolean, string]>;

	LoadKeep(key: string, unReleasedHandler?: UnReleasedHandler): Promise<Keep<T>>;
	ViewKeep(key: string, version?: string): Promise<Keep<T> | undefined>;
	PreSave(callback: (data: T) => T & object): void;
	PreLoad(callback: (data: T) => T & object): void;
	PostGlobalUpdate(key: string, updateHandler: (globalUpdates: GlobalUpdates) => unknown): Promise<void>;
}
