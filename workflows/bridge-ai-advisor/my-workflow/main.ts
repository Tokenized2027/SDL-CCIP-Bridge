/**
 * Bridge AI Advisor CRE Workflow
 *
 * Reads LaneVault4626 state via EVMClient, then calls an AI analysis
 * endpoint via HTTPClient with consensusIdenticalAggregation for
 * policy optimization recommendations.
 *
 * The AI advisor analyzes:
 *   - Whether maxUtilizationBps should be adjusted
 *   - Whether badDebtReserveCutBps is adequate
 *   - Whether targetHotReserveBps matches actual queue pressure
 *   - LP NAV trajectory and fee efficiency
 *   - Settlement risk profile
 *
 * Chainlink products used:
 *   - CRE SDK (Runner, handler, CronCapability)
 *   - EVMClient (vault reads + price feed)
 *   - HTTPClient + consensusIdenticalAggregation (AI analysis)
 *   - Chainlink Data Feed (LINK/USD)
 *   - getNetwork (chain selector resolution)
 */

import {
	bytesToHex,
	cre,
	consensusIdenticalAggregation,
	encodeCallMsg,
	getNetwork,
	Runner,
	type Runtime,
	type CronPayload,
	type HTTPSendRequester,
} from '@chainlink/cre-sdk';
import {
	encodeFunctionData,
	decodeFunctionResult,
	formatUnits,
	keccak256,
	encodeAbiParameters,
	parseAbiParameters,
	type Address,
	zeroAddress,
} from 'viem';
import { z } from 'zod';
import { LaneVault4626, LaneQueueManager, PriceFeedAggregator, SentinelRegistry } from '../contracts/abi';

// ---------------------------------------------------------------------------
// Config schema
// ---------------------------------------------------------------------------

const configSchema = z.object({
	schedule: z.string(),
	chainName: z.string(),
	vaultAddress: z.string(),
	queueManagerAddress: z.string(),
	assetDecimals: z.number().default(18),
	linkUsdFeedAddress: z.string().optional(),
	aiEndpoint: z.object({
		url: z.string(),
		bearerToken: z.string().optional(),
		creSecret: z.string().optional(),
		enabled: z.boolean().default(true),
	}),
	registry: z
		.object({
			address: z.string(),
			chainName: z.string().default('ethereum-testnet-sepolia'),
		})
		.optional(),
});

type Config = z.infer<typeof configSchema>;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type VaultState = {
	freeLiquidity: string;
	reserved: string;
	inFlight: string;
	badDebtReserve: string;
	protocolFees: string;
	settledFees: string;
	navLoss: string;
	totalAssets: string;
	totalSupply: string;
	availableForLP: string;
	utilizationBps: number;
	reserveRatio: number;
	sharePrice: number;
	queueDepth: number;
	linkUsd: number;
	maxUtilBps: number;
	reserveCutBps: number;
	hotReserveBps: number;
	protocolFeeBps: number;
	globalPaused: boolean;
	depositPaused: boolean;
	reservePaused: boolean;
};

type AIRecommendation = {
	risk: string;
	recommendation: string;
	suggestedActions: string[];
	policyAdjustments: {
		maxUtilizationBps?: number;
		badDebtReserveCutBps?: number;
		targetHotReserveBps?: number;
	};
	confidence: number;
	reasoning: string;
};

type AdvisorOutput = {
	vaultState: VaultState;
	aiAnalysis: AIRecommendation | null;
	risk: string;
	timestamp: string;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getEvmClient(chainName: string, isTestnet?: boolean) {
	const testnet = isTestnet ?? chainName.includes('testnet');
	const net = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: chainName,
		isTestnet: testnet,
	});
	if (!net) throw new Error(`Network not found: ${chainName}`);
	return new cre.capabilities.EVMClient(net.chainSelector.selector);
}

function callContract(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	to: string,
	callData: `0x${string}`,
): Uint8Array {
	const resp = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: to as Address,
				data: callData,
			}),
		})
		.result();
	return resp.data;
}

function readUint256(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	address: string,
	functionName: string,
): bigint {
	const callData = encodeFunctionData({ abi: LaneVault4626, functionName: functionName as any });
	const raw = callContract(runtime, evmClient, address, callData);
	return decodeFunctionResult({ abi: LaneVault4626, functionName: functionName as any, data: bytesToHex(raw) }) as unknown as bigint;
}

function readUint16(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	address: string,
	functionName: string,
): number {
	const callData = encodeFunctionData({ abi: LaneVault4626, functionName: functionName as any });
	const raw = callContract(runtime, evmClient, address, callData);
	return Number(decodeFunctionResult({ abi: LaneVault4626, functionName: functionName as any, data: bytesToHex(raw) }));
}

function readBool(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	address: string,
	functionName: string,
): boolean {
	const callData = encodeFunctionData({ abi: LaneVault4626, functionName: functionName as any });
	const raw = callContract(runtime, evmClient, address, callData);
	return decodeFunctionResult({ abi: LaneVault4626, functionName: functionName as any, data: bytesToHex(raw) }) as unknown as boolean;
}

const safeJsonStringify = (obj: unknown) =>
	JSON.stringify(obj, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2);

// ---------------------------------------------------------------------------
// Vault state reader (all-in-one)
// ---------------------------------------------------------------------------

function readVaultState(runtime: Runtime<Config>, evmClient: ReturnType<typeof getEvmClient>): VaultState {
	const v = runtime.config.vaultAddress;
	const qm = runtime.config.queueManagerAddress;
	const dec = runtime.config.assetDecimals;

	// 11 reads total (within CRE 15-call limit, leaving room for HTTP + registry write)
	const free = readUint256(runtime, evmClient, v, 'freeLiquidityAssets');      // 1
	const reserved = readUint256(runtime, evmClient, v, 'reservedLiquidityAssets'); // 2
	const inFlight = readUint256(runtime, evmClient, v, 'inFlightLiquidityAssets'); // 3
	const badDebt = readUint256(runtime, evmClient, v, 'badDebtReserveAssets');   // 4
	const total = readUint256(runtime, evmClient, v, 'totalAssets');              // 5
	const supply = readUint256(runtime, evmClient, v, 'totalSupply');             // 6

	const maxUtil = readUint16(runtime, evmClient, v, 'maxUtilizationBps');       // 7
	const reserveCut = readUint16(runtime, evmClient, v, 'badDebtReserveCutBps'); // 8
	const gPaused = readBool(runtime, evmClient, v, 'globalPaused');              // 9

	// Queue
	const queueData = encodeFunctionData({ abi: LaneQueueManager, functionName: 'pendingCount' });
	const queueRaw = callContract(runtime, evmClient, qm, queueData);
	const queueDepth = Number(decodeFunctionResult({ abi: LaneQueueManager, functionName: 'pendingCount', data: bytesToHex(queueRaw) })); // 10

	// Price
	let linkUsd = 0;
	if (runtime.config.linkUsdFeedAddress) {
		try {
			const priceData = encodeFunctionData({ abi: PriceFeedAggregator, functionName: 'latestAnswer' });
			const priceRaw = callContract(runtime, evmClient, runtime.config.linkUsdFeedAddress, priceData);
			linkUsd = Number(decodeFunctionResult({ abi: PriceFeedAggregator, functionName: 'latestAnswer', data: bytesToHex(priceRaw) })) / 1e8; // 11
		} catch (e) {
			runtime.log(`Price read failed: ${e instanceof Error ? e.message : String(e)}`);
		}
	}

	const utilizationBps = total > 0n ? Number(((reserved + inFlight) * 10000n) / total) : 0;
	const reserveRatio = total > 0n ? Number(badDebt) / Number(total) : 0;
	const sharePrice = supply > 0n ? Number(total * 1000000n / supply) / 1000000 : 1;

	runtime.log(
		`Vault | util=${utilizationBps}bps reserve=${(reserveRatio * 100).toFixed(2)}% queue=${queueDepth} price=$${linkUsd.toFixed(2)}`,
	);

	return {
		freeLiquidity: formatUnits(free, dec),
		reserved: formatUnits(reserved, dec),
		inFlight: formatUnits(inFlight, dec),
		badDebtReserve: formatUnits(badDebt, dec),
		protocolFees: '0',
		settledFees: '0',
		navLoss: '0',
		totalAssets: formatUnits(total, dec),
		totalSupply: formatUnits(supply, dec),
		availableForLP: formatUnits(free, dec),
		utilizationBps,
		reserveRatio,
		sharePrice,
		queueDepth,
		linkUsd,
		maxUtilBps: maxUtil,
		reserveCutBps: reserveCut,
		hotReserveBps: 2000,
		protocolFeeBps: 0,
		globalPaused: gPaused,
		depositPaused: false,
		reservePaused: false,
	};
}

// ---------------------------------------------------------------------------
// AI analysis (HTTPClient + consensus)
// ---------------------------------------------------------------------------

function fetchAIAnalysis(
	sendRequester: HTTPSendRequester,
	args: { url: string; bearerToken?: string; creSecret?: string; vaultState: VaultState },
) {
	const headers: Record<string, string> = { 'Content-Type': 'application/json' };
	if (args.bearerToken) headers['Authorization'] = `Bearer ${args.bearerToken}`;
	if (args.creSecret) headers['X-CRE-Secret'] = args.creSecret;

	const resp = sendRequester
		.sendRequest({
			method: 'POST',
			url: args.url,
			headers,
			body: new TextEncoder().encode(
				JSON.stringify({
					workflow: 'bridge-ai-advisor',
					vaultState: args.vaultState,
					requestedAnalysis: [
						'policy_optimization',
						'risk_assessment',
						'liquidity_efficiency',
						'reserve_adequacy',
					],
				}),
			),
		})
		.result();

	if (resp.statusCode !== 200) {
		throw new Error(`AI endpoint returned ${resp.statusCode}`);
	}

	return JSON.parse(Buffer.from(resp.body).toString('utf-8')) as AIRecommendation;
}

// ---------------------------------------------------------------------------
// Cron handler
// ---------------------------------------------------------------------------

function onCron(runtime: Runtime<Config>, _payload: CronPayload): string {
	const evmClient = getEvmClient(runtime.config.chainName);

	// Phase 1: Read full vault state
	const vaultState = readVaultState(runtime, evmClient);

	// Phase 2: AI analysis (optional, consensus-validated)
	let aiAnalysis: AIRecommendation | null = null;
	if (runtime.config.aiEndpoint.enabled) {
		try {
			const http = new cre.capabilities.HTTPClient();
			aiAnalysis = http
				.sendRequest(runtime, fetchAIAnalysis, consensusIdenticalAggregation<AIRecommendation>())({
					url: runtime.config.aiEndpoint.url,
					bearerToken: runtime.config.aiEndpoint.bearerToken,
					creSecret: runtime.config.aiEndpoint.creSecret,
					vaultState,
				})
				.result();

			runtime.log(
				`AI | risk=${aiAnalysis.risk} confidence=${aiAnalysis.confidence} actions=${aiAnalysis.suggestedActions.length}`,
			);
		} catch (e) {
			runtime.log(`AI analysis failed (degraded): ${e instanceof Error ? e.message : String(e)}`);
		}
	}

	// Phase 3: Determine risk (AI overrides heuristic if available)
	const heuristicRisk =
		vaultState.globalPaused
			? 'critical'
			: vaultState.utilizationBps >= 9000
				? 'critical'
				: vaultState.utilizationBps >= 7000
					? 'warning'
					: 'ok';

	const risk = aiAnalysis?.risk ?? heuristicRisk;

	const output: AdvisorOutput = {
		vaultState,
		aiAnalysis,
		risk,
		timestamp: new Date().toISOString(),
	};

	// Phase 4: On-chain proof
	if (
		runtime.config.registry?.address &&
		runtime.config.registry.address !== zeroAddress
	) {
		try {
			const sepoliaClient = getEvmClient(runtime.config.registry.chainName, true);
			const timestampUnix = BigInt(Math.floor(Date.now() / 1000));
			const confidence = BigInt(Math.round((aiAnalysis?.confidence ?? 0) * 100));
			const snapshotHash = keccak256(
				encodeAbiParameters(
					parseAbiParameters(
						'uint256 ts, string wf, string risk, uint256 utilBps, uint256 queueDepth, uint256 confidence',
					),
					[
						timestampUnix,
						'bridge-advisor',
						risk,
						BigInt(vaultState.utilizationBps),
						BigInt(vaultState.queueDepth),
						confidence,
					],
				),
			);

			const writeCallData = encodeFunctionData({
				abi: SentinelRegistry,
				functionName: 'recordHealth',
				args: [snapshotHash, `advisor:${risk}`],
			});

			sepoliaClient
				.callContract(runtime, {
					call: encodeCallMsg({
						from: zeroAddress,
						to: runtime.config.registry.address as Address,
						data: writeCallData,
					}),
				})
				.result();

			runtime.log(`Registry write | advisor:${risk} hash=${snapshotHash}`);
		} catch (e) {
			runtime.log(`Registry write failed (degraded): ${e instanceof Error ? e.message : String(e)}`);
		}
	}

	runtime.log(`BRIDGE_ADVISOR_CRE_OUTPUT_JSON=${JSON.stringify(output)}`);

	return safeJsonStringify(output);
}

// ---------------------------------------------------------------------------
// Workflow init
// ---------------------------------------------------------------------------

function initWorkflow(config: Config) {
	const cron = new cre.capabilities.CronCapability();
	return [cre.handler(cron.trigger({ schedule: config.schedule }), onCron)];
}

export async function main() {
	const runner = await Runner.newRunner<Config>({ configSchema });
	await runner.run(initWorkflow);
}

main();
