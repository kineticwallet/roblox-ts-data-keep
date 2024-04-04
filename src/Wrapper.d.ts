import type Keep from "./Keep";

declare interface Wrapper {
	onDataChanged<T extends object, C extends Callback>(
		keep: Keep<T>,
		dataPath: string,
		callback: C,
	): RBXScriptConnection | undefined;
	Mutate<T extends object>(
		keep: Keep<T>,
		dataPath: string,
		processor: (data: Partial<T> & object) => Partial<T> & object,
	): void;
}

export declare const Wrapper: Wrapper;
