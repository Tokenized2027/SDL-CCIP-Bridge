/**
 * Vault Health CRE Workflow
 *
 * Monitors LaneVault4626 liquidity state via EVMClient reads.
 * Reads core accounting buckets, key policy parameters, pause flag,
 * queue depth, and asset price from Chainlink Data Feed.
 * Classifies vault risk and writes proof hash to SentinelRegistry on Sepolia.
 *
 * NOTE: CRE imposes a 15-read limit per workflow. We use 11 reads + 1 write = 12 total.
 *
 * Chainlink products used:
 *   - CRE SDK (Runner, handler, CronCapability)
 *   - EVMClient (vault reads + price feed + queue + registry write)
 *   - Chainlink Data Feed (LINK/USD via latestAnswer)
 *   - getNetwork (chain selector resolution)
 */

import {
	bytesToHex,
	cre,
	encodeCallMsg,
	getNetwork,
	Runner,
	type Runtime,
	type CronPayload,
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
	registry: z
		.object({
			address: z.string(),
			chainName: z.string().default('ethereum-testnet-sepolia'),
		})
		.optional(),
	thresholds: z
		.object({
			utilizationWarningBps: z.number().default(7000),
			utilizationCriticalBps: z.number().default(9000),
			reserveWarningRatio: z.number().default(0.05),
			reserveCriticalRatio: z.number().default(0.02),
			queueWarningCount: z.number().default(5),
			queueCriticalCount: z.number().default(20),
		})
		.optional(),
});

type Config = z.infer<typeof configSchema>;

// ---------------------------------------------------------------------------
// Output types (trimmed for CRE 15-read budget)
// ---------------------------------------------------------------------------

type BucketSnapshot = {
	freeLiquidityAssets: string;
	reservedLiquidityAssets: string;
	inFlightLiquidityAssets: string;
	badDebtReserveAssets: string;
	totalAssets: string;
	totalSupply: string;
};

type PolicySnapshot = {
	maxUtilizationBps: number;
	badDebtReserveCutBps: number;
};

type PauseSnapshot = {
	globalPaused: boolean;
};

type HealthMetrics = {
	utilizationBps: number;
	badDebtReserveRatio: number;
	queueDepth: number;
	sharePrice: number;
	linkUsd: number;
	tvlUsd: number;
};

type VaultHealthOutput = {
	buckets: BucketSnapshot;
	policy: PolicySnapshot;
	paused: PauseSnapshot;
	health: HealthMetrics;
	risk: string;
	signal: string;
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
	const callData = encodeFunctionData({
		abi: LaneVault4626,
		functionName: functionName as any,
	});
	const raw = callContract(runtime, evmClient, address, callData);
	const decoded = decodeFunctionResult({
		abi: LaneVault4626,
		functionName: functionName as any,
		data: bytesToHex(raw),
	});
	return decoded as unknown as bigint;
}

function readUint16(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	address: string,
	functionName: string,
): number {
	const callData = encodeFunctionData({
		abi: LaneVault4626,
		functionName: functionName as any,
	});
	const raw = callContract(runtime, evmClient, address, callData);
	const decoded = decodeFunctionResult({
		abi: LaneVault4626,
		functionName: functionName as any,
		data: bytesToHex(raw),
	});
	return Number(decoded);
}

function readBool(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
	address: string,
	functionName: string,
): boolean {
	const callData = encodeFunctionData({
		abi: LaneVault4626,
		functionName: functionName as any,
	});
	const raw = callContract(runtime, evmClient, address, callData);
	const decoded = decodeFunctionResult({
		abi: LaneVault4626,
		functionName: functionName as any,
		data: bytesToHex(raw),
	});
	return decoded as unknown as boolean;
}

const safeJsonStringify = (obj: unknown) =>
	JSON.stringify(obj, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2);

// ---------------------------------------------------------------------------
// Readers (11 reads total, within CRE 15-read limit)
// ---------------------------------------------------------------------------

function readBuckets(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
): BucketSnapshot {
	const vault = runtime.config.vaultAddress;

	// 4 core buckets + 2 totals = 6 reads
	const free = readUint256(runtime, evmClient, vault, 'freeLiquidityAssets');
	const reserved = readUint256(runtime, evmClient, vault, 'reservedLiquidityAssets');
	const inFlight = readUint256(runtime, evmClient, vault, 'inFlightLiquidityAssets');
	const badDebt = readUint256(runtime, evmClient, vault, 'badDebtReserveAssets');
	const total = readUint256(runtime, evmClient, vault, 'totalAssets');
	const supply = readUint256(runtime, evmClient, vault, 'totalSupply');

	const dec = runtime.config.assetDecimals;
	runtime.log(
		`Buckets | free=${formatUnits(free, dec)} reserved=${formatUnits(reserved, dec)} inFlight=${formatUnits(inFlight, dec)} badDebt=${formatUnits(badDebt, dec)} total=${formatUnits(total, dec)}`,
	);

	return {
		freeLiquidityAssets: free.toString(),
		reservedLiquidityAssets: reserved.toString(),
		inFlightLiquidityAssets: inFlight.toString(),
		badDebtReserveAssets: badDebt.toString(),
		totalAssets: total.toString(),
		totalSupply: supply.toString(),
	};
}

function readPolicy(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
): PolicySnapshot {
	const vault = runtime.config.vaultAddress;

	// 2 policy reads (only those needed for risk classification)
	const maxUtil = readUint16(runtime, evmClient, vault, 'maxUtilizationBps');
	const reserveCut = readUint16(runtime, evmClient, vault, 'badDebtReserveCutBps');

	runtime.log(`Policy | maxUtil=${maxUtil}bps reserveCut=${reserveCut}bps`);

	return {
		maxUtilizationBps: maxUtil,
		badDebtReserveCutBps: reserveCut,
	};
}

function readPauseState(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
): PauseSnapshot {
	const vault = runtime.config.vaultAddress;

	// 1 pause read (global only, most critical)
	const global = readBool(runtime, evmClient, vault, 'globalPaused');

	runtime.log(`Pause | global=${global}`);

	return { globalPaused: global };
}

function readQueueDepth(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
): number {
	const qm = runtime.config.queueManagerAddress;
	// 1 queue read
	const callData = encodeFunctionData({
		abi: LaneQueueManager,
		functionName: 'pendingCount',
	});
	const raw = callContract(runtime, evmClient, qm, callData);
	const decoded = decodeFunctionResult({
		abi: LaneQueueManager,
		functionName: 'pendingCount',
		data: bytesToHex(raw),
	});
	const count = Number(decoded);
	runtime.log(`Queue | pending=${count}`);
	return count;
}

function readLinkUsd(
	runtime: Runtime<Config>,
	evmClient: ReturnType<typeof getEvmClient>,
): number {
	const feedAddr = runtime.config.linkUsdFeedAddress;
	if (!feedAddr) return 0;

	// 1 price read
	try {
		const callData = encodeFunctionData({
			abi: PriceFeedAggregator,
			functionName: 'latestAnswer',
		});
		const raw = callContract(runtime, evmClient, feedAddr, callData);
		const decoded = decodeFunctionResult({
			abi: PriceFeedAggregator,
			functionName: 'latestAnswer',
			data: bytesToHex(raw),
		});
		const price = Number(decoded) / 1e8;
		runtime.log(`Price | LINK/USD=${price.toFixed(2)}`);
		return price;
	} catch (e) {
		runtime.log(`Price read failed (degraded): ${e instanceof Error ? e.message : String(e)}`);
		return 0;
	}
}

// ---------------------------------------------------------------------------
// Risk classification
// ---------------------------------------------------------------------------

function classifyRisk(
	buckets: BucketSnapshot,
	paused: PauseSnapshot,
	queueDepth: number,
	thresholds: Config['thresholds'],
): { risk: string; signal: string } {
	const t = {
		utilizationWarningBps: thresholds?.utilizationWarningBps ?? 7000,
		utilizationCriticalBps: thresholds?.utilizationCriticalBps ?? 9000,
		reserveWarningRatio: thresholds?.reserveWarningRatio ?? 0.05,
		reserveCriticalRatio: thresholds?.reserveCriticalRatio ?? 0.02,
		queueWarningCount: thresholds?.queueWarningCount ?? 5,
		queueCriticalCount: thresholds?.queueCriticalCount ?? 20,
	};

	if (paused.globalPaused) return { risk: 'critical', signal: 'Global pause active' };

	const totalAssets = BigInt(buckets.totalAssets);
	const reserved = BigInt(buckets.reservedLiquidityAssets);
	const inFlight = BigInt(buckets.inFlightLiquidityAssets);
	const badDebt = BigInt(buckets.badDebtReserveAssets);

	const utilizationBps =
		totalAssets > 0n ? Number(((reserved + inFlight) * 10000n) / totalAssets) : 0;
	const reserveRatio = totalAssets > 0n ? Number(badDebt) / Number(totalAssets) : 0;

	const signals: string[] = [];

	if (utilizationBps >= t.utilizationCriticalBps) {
		signals.push(`Utilization critical: ${utilizationBps}bps >= ${t.utilizationCriticalBps}bps`);
	} else if (utilizationBps >= t.utilizationWarningBps) {
		signals.push(`Utilization warning: ${utilizationBps}bps >= ${t.utilizationWarningBps}bps`);
	}

	if (reserveRatio < t.reserveCriticalRatio && totalAssets > 0n) {
		signals.push(`Reserve critical: ${(reserveRatio * 100).toFixed(2)}% < ${t.reserveCriticalRatio * 100}%`);
	} else if (reserveRatio < t.reserveWarningRatio && totalAssets > 0n) {
		signals.push(`Reserve warning: ${(reserveRatio * 100).toFixed(2)}% < ${t.reserveWarningRatio * 100}%`);
	}

	if (queueDepth >= t.queueCriticalCount) {
		signals.push(`Queue critical: ${queueDepth} pending >= ${t.queueCriticalCount}`);
	} else if (queueDepth >= t.queueWarningCount) {
		signals.push(`Queue warning: ${queueDepth} pending >= ${t.queueWarningCount}`);
	}

	const hasCritical = signals.some((s) => s.includes('critical'));
	const hasWarning = signals.some((s) => s.includes('warning'));

	const risk = hasCritical ? 'critical' : hasWarning ? 'warning' : 'ok';
	const signal = signals.length > 0 ? signals.join('; ') : 'All systems nominal';

	return { risk, signal };
}

// ---------------------------------------------------------------------------
// Cron handler
// Read budget: 6 (buckets) + 2 (policy) + 1 (pause) + 1 (queue) + 1 (price) = 11 reads
// Write budget: 1 (registry) = 1 write
// Total: 12 operations (within CRE 15-call limit)
// ---------------------------------------------------------------------------

function onCron(runtime: Runtime<Config>, _payload: CronPayload): string {
	const evmClient = getEvmClient(runtime.config.chainName);

	// Phase 1: Read vault state (11 reads)
	const buckets = readBuckets(runtime, evmClient);
	const policy = readPolicy(runtime, evmClient);
	const paused = readPauseState(runtime, evmClient);
	const queueDepth = readQueueDepth(runtime, evmClient);
	const linkUsd = readLinkUsd(runtime, evmClient);

	// Phase 2: Compute health metrics
	const totalAssets = BigInt(buckets.totalAssets);
	const totalSupply = BigInt(buckets.totalSupply);
	const reserved = BigInt(buckets.reservedLiquidityAssets);
	const inFlight = BigInt(buckets.inFlightLiquidityAssets);
	const badDebt = BigInt(buckets.badDebtReserveAssets);

	const utilizationBps =
		totalAssets > 0n ? Number(((reserved + inFlight) * 10000n) / totalAssets) : 0;
	const reserveRatio = totalAssets > 0n ? Number(badDebt) / Number(totalAssets) : 0;
	const sharePrice =
		totalSupply > 0n ? Number(totalAssets * 1000000n / totalSupply) / 1000000 : 1;
	const totalAssetsFloat = Number(formatUnits(totalAssets, runtime.config.assetDecimals));
	const tvlUsd = totalAssetsFloat * linkUsd;

	const health: HealthMetrics = {
		utilizationBps,
		badDebtReserveRatio: reserveRatio,
		queueDepth,
		sharePrice,
		linkUsd,
		tvlUsd,
	};

	// Phase 3: Classify risk
	const { risk, signal } = classifyRisk(buckets, paused, queueDepth, runtime.config.thresholds);
	runtime.log(`Risk | vault:${risk} | ${signal}`);

	const output: VaultHealthOutput = {
		buckets,
		policy,
		paused,
		health,
		risk,
		signal,
		timestamp: new Date().toISOString(),
	};

	// Phase 4: On-chain proof write to SentinelRegistry (1 write)
	if (
		runtime.config.registry?.address &&
		runtime.config.registry.address !== zeroAddress
	) {
		try {
			const sepoliaClient = getEvmClient(runtime.config.registry.chainName, true);
			const timestampUnix = BigInt(Math.floor(Date.now() / 1000));
			const snapshotHash = keccak256(
				encodeAbiParameters(
					parseAbiParameters(
						'uint256 ts, string wf, string risk, uint256 utilBps, uint256 totalAssets, uint256 freeLiq, uint256 queueDepth, uint256 reserveRatio, uint256 sharePrice',
					),
					[
						timestampUnix,
						'vault-health',
						risk,
						BigInt(utilizationBps),
						BigInt(buckets.totalAssets),
						BigInt(buckets.freeLiquidityAssets),
						BigInt(queueDepth),
						BigInt(Math.round(reserveRatio * 1e6)),
						BigInt(Math.round(sharePrice * 1e6)),
					],
				),
			);

			const writeCallData = encodeFunctionData({
				abi: SentinelRegistry,
				functionName: 'recordHealth',
				args: [snapshotHash, `vault:${risk}`],
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

			runtime.log(`Registry write | vault:${risk} hash=${snapshotHash}`);
		} catch (e) {
			runtime.log(
				`Registry write failed (degraded): ${e instanceof Error ? e.message : String(e)}`,
			);
		}
	}

	runtime.log(`VAULT_HEALTH_CRE_OUTPUT_JSON=${JSON.stringify(output)}`);

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
