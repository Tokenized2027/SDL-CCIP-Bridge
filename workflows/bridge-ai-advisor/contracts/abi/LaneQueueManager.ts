export const LaneQueueManager = [
	{
		name: 'pendingCount',
		type: 'function',
		stateMutability: 'view',
		inputs: [],
		outputs: [{ name: '', type: 'uint256' }],
	},
	{
		name: 'headRequestId',
		type: 'function',
		stateMutability: 'view',
		inputs: [],
		outputs: [{ name: '', type: 'uint256' }],
	},
	{
		name: 'tailRequestId',
		type: 'function',
		stateMutability: 'view',
		inputs: [],
		outputs: [{ name: '', type: 'uint256' }],
	},
	{
		name: 'peek',
		type: 'function',
		stateMutability: 'view',
		inputs: [],
		outputs: [
			{ name: 'exists', type: 'bool' },
			{
				name: 'request',
				type: 'tuple',
				components: [
					{ name: 'requestId', type: 'uint256' },
					{ name: 'owner', type: 'address' },
					{ name: 'receiver', type: 'address' },
					{ name: 'shares', type: 'uint256' },
					{ name: 'enqueuedAt', type: 'uint64' },
				],
			},
		],
	},
	{
		name: 'getRequest',
		type: 'function',
		stateMutability: 'view',
		inputs: [{ name: 'requestId', type: 'uint256' }],
		outputs: [
			{
				name: '',
				type: 'tuple',
				components: [
					{ name: 'requestId', type: 'uint256' },
					{ name: 'owner', type: 'address' },
					{ name: 'receiver', type: 'address' },
					{ name: 'shares', type: 'uint256' },
					{ name: 'enqueuedAt', type: 'uint64' },
				],
			},
		],
	},
] as const;
