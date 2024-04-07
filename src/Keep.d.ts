import type { Signal } from "@rbxts/lemon-signal/dist/LemonSignal";
import type { ActiveSession } from "./Store";

declare type MetaData = {
	ActiveSession: ActiveSession | undefined;
	ForceLoad: ActiveSession | undefined;
	LastUpdate: number;
	Created: number;
	LoadCount: number;
};

declare type GlobalUpdate = {
	Data: unknown & object;
	ID: number;
};

declare type GlobalUpdates = {
	ID: number;
	Updates: GlobalUpdate[];
};

declare type Version = string;

declare interface VersionIterator {
	Current: () => Version | undefined;
	Next: () => Version | undefined;
	Previous: () => Version | undefined;
	PageUp: () => void;
	PageDown: () => void;
	SkipEnd: () => void;
	SkipStart: () => void;
}

declare interface Keep<T extends object> {
	GlobalStateProcessor: (updateData: GlobalUpdate, lock: () => boolean, remove: () => boolean) => void;

	readonly OnGlobalUpdate: Signal<[updateData: object, updateId: number]>;
	readonly Releasing: Signal<Promise<DataStoreKeyInfo | object>>;
	readonly Saving: Signal<Promise<DataStoreKeyInfo | object>>;

	Data: T

	Save(): Promise<DataStoreKeyInfo>;
	Overwrite(): Promise<DataStoreKeyInfo>;
	IsActive(): boolean;
	Identify(): string;
	GetKeyInfo(): DataStoreKeyInfo;
	Release(): Promise<Keep<T>>;
	Reconcile(): void;
	AddUserId(userId: number): void;
	RemoveUserId(userId: number): void;
	GetVersions(minDate?: number, maxDate?: number): VersionIterator;
	SetVersion(version: Version, migrateProcess: (keep: Keep<T>) => Keep<T & object>): Promise<Keep<T & object>>;
	GetActiveGlobalUpdates(): GlobalUpdate[];
	GetLockedGlobalUpdates(): GlobalUpdate[];
	ClearLockedUpdate(id: number): Promise<void>;
}

declare const Keep: Keep<object>;

export = Keep;
