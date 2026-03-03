export const SentinelRegistry = [
	{
		name: 'recordHealth',
		type: 'function',
		stateMutability: 'nonpayable',
		inputs: [
			{ name: 'snapshotHash', type: 'bytes32' },
			{ name: 'riskLevel', type: 'string' },
		],
		outputs: [],
	},
	{
		name: 'recorded',
		type: 'function',
		stateMutability: 'view',
		inputs: [{ name: '', type: 'bytes32' }],
		outputs: [{ name: '', type: 'bool' }],
	},
	{
		name: 'count',
		type: 'function',
		stateMutability: 'view',
		inputs: [],
		outputs: [{ name: '', type: 'uint256' }],
	},
] as const;
