import {promises as fsPromises} from 'fs';
import os from 'os';
import {createHash} from 'crypto';
import {execFile} from 'child_process';
import {promisify} from 'util';
import path from 'path';
import StreamZip from 'node-stream-zip';
import plist from 'plist';
import {Store} from './client.js';
import {appPriceInfo} from './catalog.js';
import {readCookieJar, restoreCookieJar} from './gsa.js';
import {SignatureClient} from './Signature.js';
import {download} from './downloader.js';
import {t} from './i18n.js';

const execFileAsync = promisify(execFile);

let infoPlistTempSeq = 0;

// Info.plist 多为二进制格式，plist 库只认 XML，交给 macOS 自带的 plutil 转换。
async function parsePlistBuffer(buffer) {
    if (buffer.subarray(0, 6).toString('latin1') !== 'bplist') {
        return plist.parse(buffer.toString('utf8'));
    }
    const tmp = path.join(os.tmpdir(), `pastel-info-${process.pid}-${infoPlistTempSeq++}.plist`);
    await fsPromises.writeFile(tmp, buffer);
    try {
        const {stdout} = await execFileAsync('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', tmp], {
            maxBuffer: 32 * 1024 * 1024,
        });
        return plist.parse(stdout);
    } finally {
        await fsPromises.rm(tmp, {force: true}).catch(() => {});
    }
}

// 读取 Payload/<App>.app/Info.plist；同名条目取路径最短的那个，即主 App 而非扩展。
async function readAppInfoPlist(ipaPath) {
    const zip = new StreamZip.async({file: ipaPath});
    try {
        const entries = await zip.entries();
        const entry = Object.values(entries)
            .filter(e => !e.isDirectory && /^Payload\/[^/]+\.app\/Info\.plist$/i.test(e.name))
            .sort((a, b) => a.name.length - b.name.length)[0];
        if (!entry) return null;
        return await parsePlistBuffer(await zip.entryData(entry.name));
    } finally {
        await zip.close().catch(() => {});
    }
}

function sanitizeFileNamePart(value) {
    if (typeof value !== 'string') return '';
    return value.replace(/[\/\\:\x00-\x1f]/g, '').replace(/^\.+/, '').trim();
}

const SESSION_TTL_MS = Number(process.env.IPA_SESSION_TTL_MS || 365 * 24 * 60 * 60 * 1000);
const SESSION_FLOW_VERSION = 'appstore-direct-v1';
const ACCEPTED_SESSION_FLOW_VERSIONS = new Set([SESSION_FLOW_VERSION, 'gsa-srp-v10']);

function appSupportDir() {
    if (process.env.IPA_SESSION_DIR) return process.env.IPA_SESSION_DIR;
    if (process.platform === 'darwin') {
        return path.join(os.homedir(), 'Library', 'Application Support', 'IPA Download', 'sessions');
    }
    if (process.platform === 'win32') {
        return path.join(process.env.APPDATA || os.homedir(), 'IPA Download', 'sessions');
    }
    return path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'IPA Download', 'sessions');
}

function sessionFileFor(email) {
    const normalizedEmail = String(email || '').trim().toLowerCase();
    const digest = createHash('sha256').update(normalizedEmail).digest('hex');
    return path.join(appSupportDir(), `${digest}.json`);
}

function validSessionFor(email, session) {
    if (!session || typeof session !== 'object') return false;
    if (!ACCEPTED_SESSION_FLOW_VERSIONS.has(session.flowVersion)) return false;
    if (String(session.appleAccount || '').trim().toLowerCase() !== String(email || '').trim().toLowerCase()) return false;
    if (SESSION_TTL_MS > 0 && session.savedAt && Date.now() - Number(session.savedAt) > SESSION_TTL_MS) return false;
    const authHeaders = session.user?.authHeaders;
    return Boolean(authHeaders?.['X-Token'] && authHeaders?.['X-Dsid']);
}

export class Ipa {
    constructor({APPLE_ID, PASSWORD, CODE}) {
        this.creds = {APPLE_ID, PASSWORD, CODE};
        this.user = null;
        this.auth = {};
        this.dir = '.';
        this.out = '';
        this.cache = '';
        this.sessionFile = sessionFileFor(APPLE_ID);
        this.usedCachedSession = false;
    }

    async loadSessionEntry() {
        try {
            const raw = await fsPromises.readFile(this.sessionFile, 'utf8');
            return JSON.parse(raw);
        } catch {
            return null;
        }
    }

    async loadSession() {
        const session = await this.loadSessionEntry();
        if (!validSessionFor(this.creds.APPLE_ID, session)) return null;
        return session.user;
    }

    async saveSession(user) {
        const session = {
            appleAccount: String(this.creds.APPLE_ID || '').trim().toLowerCase(),
            flowVersion: SESSION_FLOW_VERSION,
            savedAt: Date.now(),
            user: {
                accountInfo: user.accountInfo,
                dsPersonId: user.dsPersonId,
                pod: user.pod || '',
                authHeaders: user.authHeaders,
                cookieText: user.cookieText || '',
            }
        };
        await fsPromises.mkdir(path.dirname(this.sessionFile), {recursive: true, mode: 0o700});
        await fsPromises.writeFile(this.sessionFile, JSON.stringify(session), {mode: 0o600});
    }

    async clearSession() {
        await fsPromises.rm(this.sessionFile, {force: true}).catch(() => {});
        this.usedCachedSession = false;
    }

    applyUser(user, usedCachedSession) {
        this.user = user;
        this.auth = {
            authHeaders: user.authHeaders,
            pod: user.pod || '',
            cookieJar: restoreCookieJar(user.cookieText, this.creds.APPLE_ID),
        };
        this.usedCachedSession = usedCachedSession;
    }

    async login({force = false} = {}) {
        const previousSessionEntry = await this.loadSessionEntry();
        const previousSession = previousSessionEntry?.user || null;
        if (!force) {
            const cachedUser = validSessionFor(this.creds.APPLE_ID, previousSessionEntry) ? previousSession : null;
            if (cachedUser) {
                console.log(t('login_local_session', {id: this.creds.APPLE_ID}));
                this.applyUser(cachedUser, true);
                return;
            }
        }

        const user = await Store.login(this.creds.APPLE_ID, this.creds.PASSWORD, this.creds.CODE, previousSession);
        console.log(t('login_success', {name: `${user.accountInfo.address.firstName} ${user.accountInfo.address.lastName}`}));
        this.applyUser(user, false);
        await this.saveSession(user).catch(error => {
            console.log(t('save_session_failed', {message: error.message}));
        });
    }

    async persistCurrentSession() {
        if (!this.user) return;
        const cookieText = readCookieJar(this.auth.cookieJar);
        if (cookieText) this.user.cookieText = cookieText;
        await this.saveSession(this.user);
    }

    async info(APPID, appVerId) {
        const appInfo = await Store.AppInfo(APPID, appVerId, this.auth);
        const s = appInfo?.songList?.[0];
        const name = s?.metadata?.bundleDisplayName || 'UnknownApp';
        const ver = s?.metadata?.bundleShortVersionString || 'UnknownVer';
        console.log(t('app_info', {name, ver}));
        const noUpdateSuffix = process.env.IPA_REMOVE_APP_STORE_UPDATE_METADATA === '1' ? '_no-update' : '';
        this.out = path.join(this.dir, `${name}_${ver}${noUpdateSuffix}.ipa`);
        return s;
    }

    // Apple 元数据缺名称/版本时（老 App 常见）文件名会带 UnknownApp / UnknownVer 占位。
    // 包已经在本地了，直接读 IPA 内的 Info.plist 取真实值改名。
    async correctOutputName(song) {
        const meta = song?.metadata || {};
        const needName = !meta.bundleDisplayName;
        const needVersion = !meta.bundleShortVersionString;
        if (!needName && !needVersion) return;

        const info = await readAppInfoPlist(this.out).catch(() => null);
        if (!info) return;

        const name = needName ? sanitizeFileNamePart(info.CFBundleDisplayName || info.CFBundleName) : '';
        const version = needVersion
            ? sanitizeFileNamePart(info.CFBundleShortVersionString || info.CFBundleVersion)
            : '';
        if (!name && !version) return;

        const current = path.basename(this.out, '.ipa');
        const suffix = current.endsWith('_no-update') ? '_no-update' : '';
        const base = suffix ? current.slice(0, -suffix.length) : current;
        const underscore = base.lastIndexOf('_');
        const currentName = underscore > 0 ? base.slice(0, underscore) : base;
        const currentVersion = underscore > 0 ? base.slice(underscore + 1) : '';

        const target = path.join(this.dir, `${name || currentName}_${version || currentVersion}${suffix}.ipa`);
        if (target === this.out) return;
        await fsPromises.rename(this.out, target);
        this.out = target;
        console.log(t('name_corrected', {out: target}));
    }

    // 判断 App 是否免费：优先用上层（App 界面）传入的价格信号，未知时用 iTunes lookup 兜底。
    // 仅免费 App 才允许主动申请购买许可；付费 App 一律不触发购买（已购买的会直接命中 AppInfo）。
    async isFreeApp(APPID) {
        const flag = process.env.IPA_APP_IS_FREE;
        if (flag === '1') return true;
        if (flag === '0') return false;
        const info = await appPriceInfo(APPID, {country: process.env.IPA_APP_COUNTRY || 'us'});
        // lookup 不可用（地区差异等）时按「免费」处理，保持免费 App 可用；付费 App 仍会在 buyProduct 阶段被 Apple 拒绝、不会扣费。
        return info ? info.isFree : true;
    }

    // 从 Apple 官方元数据获取该 App 的全部历史版本 ID（外部版本标识）。
    // 用于第三方来源不可用时的兜底：登录后读取 softwareVersionExternalIdentifiers。
    async listVersionIds(APPID) {
        if (!this.user) throw new Error('Please login() first');
        return await this._withReauth(() => this._listVersionIdsOnce(APPID));
    }

    async _listVersionIdsOnce(APPID) {
        // 先直接查（已购买 / 已获取过的 App 无需再申请许可，不产生任何副作用）。
        let song = await Store.AppInfo(APPID, '', this.auth).catch(error => ({_error: error}));
        if (song?._error) {
            // 用稳定的 error.code 判断「缺少许可」，不依赖文案语言；Apple 自身英文消息保留兜底。
            const noLicense = song._error.code === 'APPINFO_FAIL' || /License not found/i.test(song._error.message || '');
            if (!noLicense) throw song._error;
            // 缺少许可：仅免费 App 才主动申请；付费且未购买的 App 直接报错、绝不触发购买。
            if (!(await this.isFreeApp(APPID))) {
                throw new Error(t('paid_not_purchased'));
            }
            if (process.env.IPA_ALLOW_APP_ACQUIRE !== '1') {
                return {
                    appId: String(APPID),
                    requiresAcquisition: true,
                    versionIds: [],
                };
            }
            await Store.purchase(APPID, '', this.auth);
            song = await Store.AppInfo(APPID, '', this.auth);
        }
        const s = song?.songList?.[0];
        const meta = s?.metadata || {};
        const ids = Array.isArray(meta.softwareVersionExternalIdentifiers)
            ? meta.softwareVersionExternalIdentifiers.map(String)
            : [];
        return {
            appId: String(APPID),
            name: meta.bundleDisplayName || 'UnknownApp',
            latestVersion: meta.bundleShortVersionString || '',
            latestVersionId: String(meta.softwareVersionExternalIdentifier ?? (ids.length ? ids[ids.length - 1] : '')),
            versionIds: ids,
        };
    }

    async runDownload({dir = '.', APPID, appVerId} = {}) {
        if (!this.user) throw new Error('Please login() first');
        this.dir = dir;
        this.cache = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'ipa-history-download-parts-'));
        console.log(t('temp_dir', {cache: this.cache}));
        try {
            const purchaseResult = await Store.purchase(APPID, appVerId, this.auth);
            console.log(t('purchase_ok', {message: purchaseResult.customerMessage}));
            const song = await this.info(APPID, appVerId);
            const res = await download(song.URL, this.out, this.cache, this.auth.authHeaders || {});
            console.log(t('download_complete', {mb: (res.fileSize / 1024 / 1024).toFixed(2), parts: res.parts}));
            // 稳定的机器标记：进入「校验/签名/存档」阶段，供 App 显示「打包中」（与显示文案解耦，不随语言变化）。
            console.log('@@IPA:phase=packaging');
            const signer = new SignatureClient(song, this.user.accountInfo.appleId, {
                includeAppStoreMetadata: process.env.IPA_REMOVE_APP_STORE_UPDATE_METADATA !== '1',
            });
            await signer.sign(this.out);
            await this.correctOutputName(song).catch(() => {});

            console.log(t('file_archived', {out: this.out}));
        } finally {
            await this.persistCurrentSession().catch(() => {});
            await fsPromises.rm(this.cache, {recursive: true, force: true}).catch(() => {});
            Store.cleanup?.();
            console.log(t('cleanup_done'));
        }
    }

    async run(options = {}) {
        return await this._withReauth(() => this.runDownload(options));
    }

    // 执行 fn；若失败且疑似本地缓存会话过期，则清会话、强制重新登录（可能触发 2FA）后重试一次。
    async _withReauth(fn) {
        try {
            const result = await fn();
            await this.persistCurrentSession().catch(() => {});
            return result;
        } catch (error) {
            const message = error.message || String(error);
            // 用稳定的 error.code 判断商店会话过期（cookie/令牌失效），不依赖文案语言；Apple 英文消息保留兜底。
            const code = error.code;
            const sessionMayBeExpired = this.usedCachedSession
                && (code === 'TOKEN_EXPIRED'
                    || /401|403|Your password has changed\.?|password token is expired|token|session|authenticate|authorization|Sign In to the iTunes Store/i.test(message))
                && !/License not found|已拥有|already|not found/i.test(message);
            if (!sessionMayBeExpired) throw error;

            console.log(t('relogin'));
            await this.login({force: true});
            const result = await fn();
            await this.persistCurrentSession().catch(() => {});
            return result;
        }
    }
}
