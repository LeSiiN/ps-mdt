/** Shared impound types used by both the MDT modal and the on-site form. */

export interface ImpoundReason {
	label: string;
	fee: number;
	/** Duration id pre-selected when this reason is picked. Advisory: the officer can change it. */
	hold?: string;
}

export interface ImpoundLot {
	id: string;
	label: string;
}

/** How long the vehicle is held before it may be released at all. */
export interface ImpoundDuration {
	id: string;
	label: string;
	/** undefined = held until an officer releases it; 0 = releasable immediately. */
	days?: number;
}

export interface ImpoundConfig {
	reasons: ImpoundReason[];
	lots: ImpoundLot[];
	defaultFee: number;
	maxFee: number;
	requireFeePaid: boolean;
	storage: { perDay: number; maxDays: number };
	durations: ImpoundDuration[];
	defaultDuration: string;
}