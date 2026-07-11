/** Shared impound types used by both the MDT modal and the on-site form. */

export interface ImpoundReason {
	label: string;
	fee: number;
}

export interface ImpoundLot {
	id: string;
	label: string;
}

export interface ImpoundConfig {
	reasons: ImpoundReason[];
	lots: ImpoundLot[];
	defaultFee: number;
	maxFee: number;
	requireFeePaid: boolean;
	storage: { perDay: number; maxDays: number };
}
