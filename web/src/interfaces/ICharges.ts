export interface Charge {
	code?: string;
	label: string;
	description: string;
	time: number;
	fine?: number;
	type: "felony" | "misdemeanor" | "infraction";
	category: string;
	color?: string;
	// Which ticket types this law may be written on. Flags on the law itself,
	// so its fine is edited in one place and applies to both.
	in_citation?: boolean | number;
	in_parking?: boolean | number;
}

export interface GroupedCharges {
	felony: Record<string, Charge[]>;
	misdemeanor: Record<string, Charge[]>;
	infraction: Record<string, Charge[]>;
}