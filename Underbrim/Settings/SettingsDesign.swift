//
//  SettingsDesign.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings in Underbrim's own look: warm flat colours that follow the Mac's appearance, a sidebar
//  whose selected row is a small black island, and pages that open under an island (SettingsIsland).
//  What a setting does is behind an ⓘ on its row. Native controls throughout.
//

import Defaults
import SwiftUI

enum SettingsPalette {
    static let page = dynamic(dark: 0x161513, light: 0xF6F5F2)
    static let sidebar = dynamic(dark: 0x1C1A18, light: 0xEBE9E5)
    /// A preview's desktop, and the menu bar's band across it.
    static let stage = dynamic(dark: 0x24221F, light: 0xE4E1DB)
    static let band = dynamic(dark: 0x2F2C28, light: 0xD6D2CB)
    static let hairline = dynamic(dark: 0x2B2926, light: 0xD9D6D0)
    static let glyph = dynamic(dark: 0xA8A298, light: 0x5C5850)

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? rgb(dark) : rgb(light) })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// What Settings shows and finds a page by, kept together for each page.
struct SettingsPageInfo {
    /// The sidebar's symbol.
    let glyph: Image
    /// The page's one line on what it's for, under its name.
    let summary: String
    /// Words a search finds the page by besides its name, English and Arabic, whatever the language.
    let keywords: String
    /// The same in the other ten languages, by language (names such as Spotify are in `keywords`).
    let localKeywords: [String: String]
    /// The island it opens under.
    let islandSize: CGSize

    /// `localKeywords` in the app's language, when it's one of the ten.
    var localWords: String { Bundle.main.preferredLocalizations.first.flatMap { localKeywords[$0] } ?? "" }
}

extension SettingsTab {
    enum Group: CaseIterable {
        case underbrim, home, tabs, activities, advanced

        var title: String? {
            switch self {
            case .underbrim: "Underbrim"
            case .home: String(localized: "Home")
            case .tabs: String(localized: "Tabs")
            case .activities: String(localized: "Activities")
            case .advanced: nil
            }
        }

        var tabs: [SettingsTab] {
            switch self {
            case .underbrim: [.general, .appearance, .permissions]
            case .home: [.widgets, .media, .prayer, .calendar]
            case .tabs: [.shelf, .clipboard, .agents, .sound]
            case .activities: [.activities, .notifications, .osd]
            case .advanced: [.advanced]
            }
        }
    }

    /// The sidebar's groups with the pages the search finds; every page when there's nothing to find.
    /// About, the brand row above the groups, is found with Underbrim's own.
    @MainActor static func groups(matching query: String) -> [(Group, [SettingsTab])] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let found = Set(SettingsSearch.results(for: query).map(\.page))
        return Group.allCases.compactMap { group in
            let tabs = !searching ? group.tabs : (group == .underbrim ? group.tabs + [.about] : group.tabs).filter(found.contains)
            return tabs.isEmpty ? nil : (group, tabs)
        }
    }

    var info: SettingsPageInfo {
        switch self {
        case .general: SettingsPageInfo(
            glyph: Image(systemName: "gearshape.fill"),
            summary: String(localized: "Login, the menu bar icon, language, how the notch opens, and its shortcuts."),
            keywords: "login startup menu bar language display screen notch hover lock screen recording compact keyboard shortcuts hotkey keys scratchpad note الدخول شريط القائمة لغة شاشة نوتش تمرير قفل مضغوط لوحة المفاتيح اختصارات مفاتيح المسودة ملاحظة",
            localKeywords: [
                "de": "anmeldung autostart menüleiste sprache bildschirm monitor größe höhe zeiger verzögerung animation sperrbildschirm bildschirmaufnahme tastatur tastenkürzel tasten kurzbefehl vorschau notizblock notiz",
                "es": "inicio de sesión arranque barra de menús idioma pantalla monitor tamaño altura puntero retraso animación pantalla bloqueada grabación teclado atajos teclas vistazo bloc de notas nota",
                "fr": "connexion démarrage ouverture barre des menus langue écran moniteur taille hauteur survol délai animation écran verrouillé enregistrement clavier raccourcis touches aperçu bloc-notes note",
                "it": "login avvio accesso barra dei menu lingua schermo monitor dimensioni altezza puntatore ritardo animazione schermata di blocco registrazione tastiera scorciatoie tasti anteprima blocco note nota",
                "ja": "ログイン 起動 メニューバー 言語 ディスプレイ 画面 モニタ サイズ 大きさ 高さ ホバー 遅延 アニメーション ロック画面 画面収録 キーボード ショートカット キー プレビュー メモ",
                "ko": "로그인 시작 메뉴 막대 언어 디스플레이 화면 모니터 크기 높이 포인터 지연 애니메이션 잠금 화면 녹화 키보드 단축키 키 미리보기 메모",
                "pt-BR": "login início inicialização barra de menus idioma tela monitor tamanho altura ponteiro atraso animação tela bloqueada gravação teclado atalhos teclas espiada bloco de notas nota",
                "ru": "вход автозапуск строка меню язык экран монитор дисплей размер высота наведение задержка анимация экран блокировки запись клавиатура сочетания клавиши горячие клавиши просмотр блокнот заметка",
                "tr": "giriş başlangıç menü çubuğu dil ekran monitör boyut yükseklik imleç gecikme animasyon kilit ekranı kayıt klavye kısayollar tuşlar önizleme not defteri not",
                "zh-Hans": "登录 启动 菜单栏 语言 显示器 屏幕 大小 尺寸 高度 悬停 延迟 动画 锁屏 录屏 键盘 快捷键 按键 预览 便签 笔记"
            ],
            islandSize: CGSize(width: 230, height: 34))
        case .appearance: SettingsPageInfo(
            glyph: Image(systemName: "paintbrush.pointed.fill"),
            summary: String(localized: "Your accent color and how the open notch looks."),
            keywords: "accent color colour theme face shadow لون سمة وجه ظل",
            localKeywords: [
                "de": "akzentfarbe farbe design",
                "es": "color de acento tema",
                "fr": "couleur accentuation thème",
                "it": "colore di accento tema",
                "ja": "アクセントカラー 色 テーマ",
                "ko": "강조 색상 색 테마",
                "pt-BR": "cor de destaque tema",
                "ru": "акцент цвет тема",
                "tr": "vurgu rengi renk tema",
                "zh-Hans": "强调色 颜色 主题"
            ],
            islandSize: CGSize(width: 140, height: 38))
        case .permissions: SettingsPageInfo(
            glyph: Image(systemName: "hand.raised.fill"),
            summary: String(localized: "What Underbrim may use on this Mac, what each is for, and where to change it."),
            keywords: "privacy permissions access allow security tcc أذونات إذن خصوصية وصول سماح أمان",
            localKeywords: [
                "de": "datenschutz berechtigungen zugriff erlauben sicherheit",
                "es": "privacidad permisos acceso permitir seguridad",
                "fr": "confidentialité autorisations accès autoriser sécurité",
                "it": "privacy permessi accesso consenti sicurezza",
                "ja": "プライバシー 許可 アクセス 権限 セキュリティ",
                "ko": "개인정보 권한 접근 허용 보안",
                "pt-BR": "privacidade permissões acesso permitir segurança",
                "ru": "конфиденциальность разрешения доступ разрешить безопасность",
                "tr": "gizlilik izinler erişim izin ver güvenlik",
                "zh-Hans": "隐私 权限 访问 允许 安全"
            ],
            islandSize: CGSize(width: 270, height: 38))
        case .widgets: SettingsPageInfo(
            glyph: Image(systemName: "square.grid.2x2.fill"),
            summary: String(localized: "What Home shows, in what order and size."),
            keywords: "home quick launch order size tabs mirror camera webcam الرئيسية تشغيل سريع ترتيب حجم مرآة كاميرا",
            localKeywords: [
                "de": "start schnellstart reihenfolge größe tabs kamera spiegel",
                "es": "inicio lanzamiento rápido orden tamaño pestañas cámara espejo",
                "fr": "accueil lancement rapide ordre taille onglets caméra miroir",
                "it": "home avvio rapido ordine dimensioni schede fotocamera videocamera specchio",
                "ja": "ホーム クイック起動 並び順 順番 サイズ タブ カメラ 鏡 ミラー",
                "ko": "홈 빠른 실행 순서 크기 탭 카메라 웹캠 거울",
                "pt-BR": "início inicialização rápida ordem tamanho abas câmera espelho",
                "ru": "главная быстрый запуск порядок размер вкладки камера веб-камера зеркало",
                "tr": "ana sayfa hızlı başlatma sıra boyut sekmeler kamera ayna",
                "zh-Hans": "主页 快速启动 顺序 大小 标签页 摄像头 相机 镜子"
            ],
            islandSize: CGSize(width: 280, height: 52))
        case .media: SettingsPageInfo(
            glyph: Image(systemName: "play.fill"),
            summary: String(localized: "Where media comes from, the player's controls, and its look."),
            keywords: "media source music video player now playing spotify youtube controls موسيقى فيديو مشغل وسائط",
            localKeywords: [
                "de": "medien quelle musik video player wiedergabe steuerung",
                "es": "multimedia fuente música vídeo reproductor reproducción controles",
                "fr": "médias source musique vidéo lecteur lecture commandes",
                "it": "media sorgente musica video lettore riproduzione controlli",
                "ja": "メディア ソース 音楽 ミュージック ビデオ 動画 プレーヤー 再生中 操作",
                "ko": "미디어 소스 음악 비디오 동영상 플레이어 재생 중 제어",
                "pt-BR": "mídia fonte música vídeo player reprodutor tocando controles",
                "ru": "медиа источник музыка видео плеер воспроизведение управление",
                "tr": "medya kaynak müzik video oynatıcı çalan denetimler",
                "zh-Hans": "媒体 来源 音乐 视频 播放器 正在播放 控制"
            ],
            islandSize: CGSize(width: 300, height: 46))
        case .prayer: SettingsPageInfo(
            glyph: Image(systemName: "moon.stars.fill"),
            summary: String(localized: "Today's times where you are, and the adhan in the notch."),
            keywords: "adhan athan salah fajr dhuhr asr maghrib isha hijri method location أذان صلاة فجر ظهر عصر مغرب عشاء هجري",
            localKeywords: [
                "de": "gebet gebetszeiten fadschr dhuhr asr maghrib ischa hidschri methode standort",
                "es": "oración rezo fajr dhuhr asr magreb isha hégira método ubicación",
                "fr": "prière fajr dhohr asr maghrib icha hégire méthode position lieu",
                "it": "preghiera fajr dhuhr asr maghrib isha egira metodo posizione",
                "ja": "礼拝 アザーン ファジュル ズフル アスル マグリブ イシャー ヒジュラ 計算方法 場所",
                "ko": "기도 아잔 파즈르 두흐르 아스르 마그립 이샤 히즈라 계산법 위치",
                "pt-BR": "oração fajr dhuhr asr maghrib isha hégira método localização",
                "ru": "намаз молитва азан фаджр зухр аср магриб иша хиджра метод местоположение",
                "tr": "namaz ezan vakit imsak öğle ikindi akşam yatsı hicri yöntem konum",
                "zh-Hans": "礼拜 宣礼 晨礼 晌礼 晡礼 昏礼 宵礼 伊斯兰历 计算方法 位置"
            ],
            islandSize: CGSize(width: 250, height: 38))
        case .calendar: SettingsPageInfo(
            glyph: Image(systemName: "calendar"),
            summary: String(localized: "Meeting countdowns, today's events on Home, and which calendars."),
            keywords: "events meetings countdown reminders أحداث اجتماعات",
            localKeywords: [
                "de": "termine ereignisse besprechungen countdown erinnerungen",
                "es": "eventos reuniones cuenta atrás recordatorios",
                "fr": "événements réunions compte à rebours rappels",
                "it": "eventi riunioni conto alla rovescia promemoria",
                "ja": "イベント 予定 会議 ミーティング カウントダウン リマインダー",
                "ko": "이벤트 일정 회의 카운트다운 미리 알림",
                "pt-BR": "eventos reuniões contagem regressiva lembretes",
                "ru": "события встречи совещания обратный отсчёт напоминания",
                "tr": "etkinlikler toplantılar geri sayım anımsatıcılar",
                "zh-Hans": "事件 日程 会议 倒计时 提醒事项"
            ],
            islandSize: CGSize(width: 290, height: 38))
        case .shelf: SettingsPageInfo(
            glyph: Image(systemName: "tray.full.fill"),
            summary: String(localized: "Drop files on the notch to keep them close, then drag or share them."),
            keywords: "files drop airdrop share ملفات رف مشاركة",
            localKeywords: [
                "de": "dateien ablegen teilen ablage",
                "es": "archivos soltar compartir estante",
                "fr": "fichiers déposer partager étagère",
                "it": "file rilasciare condividere scaffale",
                "ja": "ファイル ドロップ 共有 シェルフ",
                "ko": "파일 놓기 공유 선반",
                "pt-BR": "arquivos soltar compartilhar estante",
                "ru": "файлы перетащить поделиться полка",
                "tr": "dosyalar bırak paylaş raf",
                "zh-Hans": "文件 拖放 共享 文件架"
            ],
            islandSize: CGSize(width: 240, height: 44))
        case .clipboard: SettingsPageInfo(
            glyph: Image(systemName: "list.clipboard.fill"),
            summary: String(localized: "A history of what you copy, encrypted and kept on this Mac."),
            keywords: "copy paste history نسخ لصق سجل",
            localKeywords: [
                "de": "kopieren einfügen verlauf zwischenablage",
                "es": "copiar pegar historial portapapeles",
                "fr": "copier coller historique presse-papiers",
                "it": "copia incolla cronologia appunti",
                "ja": "コピー ペースト 貼り付け 履歴 クリップボード",
                "ko": "복사 붙여넣기 기록 클립보드",
                "pt-BR": "copiar colar histórico área de transferência",
                "ru": "копировать вставить история буфер обмена",
                "tr": "kopyala yapıştır geçmiş pano",
                "zh-Hans": "拷贝 复制 粘贴 历史记录 剪贴板"
            ],
            islandSize: CGSize(width: 280, height: 38))
        case .agents: SettingsPageInfo(
            glyph: Image(systemName: "terminal.fill"),
            summary: String(localized: "Claude Code and Codex sessions in the notch, and your plan usage."),
            keywords: "claude code codex approvals usage terminal وكلاء برمجة جلسات",
            localKeywords: [
                "de": "freigaben genehmigungen nutzung terminal sitzungen",
                "es": "aprobaciones uso terminal sesiones",
                "fr": "approbations utilisation terminal sessions",
                "it": "approvazioni utilizzo terminale sessioni",
                "ja": "承認 使用量 ターミナル セッション",
                "ko": "승인 사용량 터미널 세션",
                "pt-BR": "aprovações uso terminal sessões",
                "ru": "подтверждения использование терминал сеансы",
                "tr": "onaylar kullanım terminal oturumlar",
                "zh-Hans": "批准 用量 终端 会话"
            ],
            islandSize: CGSize(width: 290, height: 38))
        case .activities: SettingsPageInfo(
            glyph: Image(systemName: "iphone.radiowaves.left.and.right"),
            summary: String(localized: "Your iPhone's Live Activities, calls, Focus, battery and downloads in the notch."),
            keywords: "iphone live activities deliveries calls focus caps lock battery charging power headphones airpods downloads safari chrome files آيفون توصيل مكالمات تركيز بطارية شحن سماعات تنزيلات ملفات",
            localKeywords: [
                "de": "live-aktivitäten lieferungen anrufe fokus feststelltaste akku laden strom kopfhörer dateien downloads herunterladen",
                "es": "actividades en directo entregas llamadas concentración bloqueo de mayúsculas batería carga energía auriculares archivos descargas",
                "fr": "activités en direct livraisons appels concentration verrouillage majuscules batterie charge alimentation écouteurs casque fichiers téléchargements",
                "it": "attività live consegne chiamate full immersion blocco maiuscole batteria ricarica alimentazione cuffie auricolari file download",
                "ja": "ライブアクティビティ 配達 通話 集中モード バッテリー 充電 電源 ヘッドフォン イヤホン ファイル ダウンロード",
                "ko": "실시간 현황 배달 통화 집중 모드 배터리 충전 전원 헤드폰 이어폰 파일 다운로드",
                "pt-BR": "atividades ao vivo entregas chamadas foco bateria carregamento energia fones de ouvido arquivos downloads transferências",
                "ru": "живые активности доставка звонки фокусирование аккумулятор батарея зарядка питание наушники файлы загрузки",
                "tr": "canlı etkinlikler teslimatlar aramalar odak büyük harf pil şarj güç kulaklık dosyalar indirmeler",
                "zh-Hans": "实时活动 外卖 快递 通话 专注模式 大写锁定 电池 充电 电源 耳机 文件 下载"
            ],
            islandSize: CGSize(width: 310, height: 40))
        case .notifications: SettingsPageInfo(
            glyph: Image(systemName: "bell.badge.fill"),
            summary: String(localized: "Banners from the apps you choose, shown in the notch."),
            keywords: "banners messages apps إشعارات رسائل تنبيهات",
            localKeywords: [
                "de": "banner nachrichten mitteilungen apps",
                "es": "banners mensajes apps notificaciones avisos",
                "fr": "bannières messages apps",
                "it": "banner messaggi app",
                "ja": "バナー メッセージ アプリ 通知",
                "ko": "배너 메시지 앱 알림",
                "pt-BR": "banners mensagens apps",
                "ru": "баннеры сообщения приложения",
                "tr": "afişler mesajlar uygulamalar",
                "zh-Hans": "横幅 信息 消息 应用"
            ],
            islandSize: CGSize(width: 270, height: 44))
        case .osd: SettingsPageInfo(
            glyph: Image(systemName: "speaker.wave.2.fill"),
            summary: String(localized: "Volume, brightness and keyboard light in the notch instead of macOS's."),
            keywords: "volume brightness keyboard backlight hud osd صوت سطوع إضاءة",
            localKeywords: [
                "de": "lautstärke ton helligkeit tastatur tastaturbeleuchtung",
                "es": "volumen sonido brillo teclado retroiluminación",
                "fr": "volume son luminosité clavier rétroéclairage",
                "it": "volume audio luminosità tastiera retroilluminazione",
                "ja": "音量 サウンド 明るさ 輝度 キーボード バックライト",
                "ko": "볼륨 음량 소리 밝기 키보드 백라이트",
                "pt-BR": "volume som brilho teclado iluminação",
                "ru": "громкость звук яркость клавиатура подсветка",
                "tr": "ses düzeyi parlaklık klavye aydınlatma",
                "zh-Hans": "音量 声音 亮度 键盘 背光"
            ],
            islandSize: CGSize(width: 330, height: 50))
        case .sound: SettingsPageInfo(
            glyph: Image(systemName: "slider.horizontal.3"),
            summary: String(localized: "A volume for each app, up to 200 %, on a page of the open notch."),
            keywords: "sound mixer app volume boost mute output speakers صوت مازج مستوى تطبيق كتم مخرج",
            localKeywords: [
                "de": "ton mixer app lautstärke verstärken stumm ausgabe lautsprecher",
                "es": "sonido mezclador volumen por app amplificar silenciar salida altavoces",
                "fr": "son mixeur volume par app amplifier couper sortie haut-parleurs",
                "it": "suono mixer volume per app amplificare silenzia uscita altoparlanti",
                "ja": "サウンド ミキサー アプリ 音量 ブースト 消音 ミュート 出力 スピーカー",
                "ko": "사운드 믹서 앱 볼륨 증폭 음소거 출력 스피커",
                "pt-BR": "som mixer volume por app amplificar silenciar saída alto-falantes",
                "ru": "звук микшер громкость приложения усиление без звука выход динамики",
                "tr": "ses mikser uygulama ses düzeyi yükseltme sessiz çıkış hoparlör",
                "zh-Hans": "声音 混音器 应用 音量 增强 静音 输出 扬声器"
            ],
            islandSize: CGSize(width: 260, height: 38))
        case .advanced: SettingsPageInfo(
            glyph: Image(systemName: "gearshape.2.fill"),
            summary: String(localized: "Settings you'd set once and rarely change, by area."),
            keywords: "advanced more options size height delay animation speed haptics mission control متقدم متقدمة خيارات المزيد حجم ارتفاع تأخير حركة سرعة",
            localKeywords: [
                "de": "erweitert weitere optionen größe höhe verzögerung animation geschwindigkeit",
                "es": "avanzado más opciones tamaño altura retraso animación velocidad",
                "fr": "avancé avancés plus d'options taille hauteur délai animation vitesse",
                "it": "avanzate avanzato altre opzioni dimensioni altezza ritardo animazione velocità",
                "ja": "詳細 詳細設定 その他 オプション サイズ 高さ 遅延 アニメーション 速度",
                "ko": "고급 추가 옵션 크기 높이 지연 애니메이션 속도",
                "pt-BR": "avançado mais opções tamanho altura atraso animação velocidade",
                "ru": "дополнительно расширенные параметры размер высота задержка анимация скорость",
                "tr": "gelişmiş diğer seçenekler boyut yükseklik gecikme animasyon hız",
                "zh-Hans": "高级 更多 选项 大小 高度 延迟 动画 速度"
            ],
            islandSize: CGSize(width: 300, height: 64))
        case .about: SettingsPageInfo(
            glyph: Image(systemName: "info.circle.fill"),
            summary: String(localized: "Version, the source and the license."),
            keywords: "version license source github إصدار رخصة مصدر",
            localKeywords: [
                "de": "version lizenz quellcode",
                "es": "versión licencia código fuente",
                "fr": "version licence code source",
                "it": "versione licenza codice sorgente",
                "ja": "バージョン ライセンス ソース",
                "ko": "버전 라이선스 소스",
                "pt-BR": "versão licença código-fonte",
                "ru": "версия лицензия исходный код",
                "tr": "sürüm lisans kaynak kodu",
                "zh-Hans": "版本 许可证 源代码"
            ],
            islandSize: CGSize(width: 240, height: 44))
        }
    }
}

/// A page's opening, in its first section's header so it scrolls with the page: its name, one line
/// on what it's for, its main switch when it has one, then that section's own title.
struct SettingsPageHeader: View {
    let tab: SettingsTab
    var isOn: Binding<Bool>?
    var section: LocalizedStringKey?
    var info: [LocalizedStringKey] = []
    var sectionMark: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(tab.info.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let isOn {
                    Toggle(isOn: isOn) { Text(tab.title) }
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.effectiveAccent)
                        .settingsItem(SettingsItem.pageSwitch)
                        .padding(.top, 6)
                }
            }
            if let section {
                SettingsLabel(section, info: info)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .modifier(OptionalMark(mark: sectionMark))
                    .padding(.top, 6)
            }
        }
        .textCase(nil)
        .padding(.bottom, section == nil ? 4 : 0)
    }
}

private struct OptionalMark: ViewModifier {
    let mark: String?

    func body(content: Content) -> some View {
        if let mark { content.settingsItem(mark) } else { content }
    }
}

/// Switches in the accent's fill (#E8961C in Light and Dark); menus and buttons take its text tone.
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).tint(.effectiveAccent)
    }
}

struct SettingsStage<Content: View>: View {
    var height: CGFloat = 104
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            SettingsPalette.stage
            SettingsPalette.band.frame(height: 22)
            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// The sidebar. Arrow keys move through the rows once it has the keyboard.
struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Bindable private var finder = SettingsSearch.shared
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var activeState

    private var shown: [(SettingsTab.Group, [SettingsTab])] { SettingsTab.groups(matching: finder.query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.bottom, 10)
            search
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown, id: \.0) { group, tabs in
                        if let title = group.title {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
                                .accessibilityAddTraits(.isHeader)
                        } else {
                            Color.clear.frame(height: 16).accessibilityHidden(true)
                        }
                        ForEach(tabs) { row($0) }
                    }
                    if shown.isEmpty {
                        Text("No Results").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            quit
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsPalette.sidebar.ignoresSafeArea())
        .focusable()
        .focused($focused)
        // Not the system's ring around the whole sidebar: the selected row shows it has the keyboard.
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
    }

    private var aboutOn: Bool { selection == .about && !finder.isSearching }
    /// Like the system's focus rings, only while the window is the key one.
    private var showsFocus: Bool { focused && activeState == .key }

    private var brand: some View {
        Button {
            finder.query = ""
            selection = .about
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .padding(-3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Underbrim").font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(aboutOn ? Color.white : .primary)
                    Text(verbatim: Bundle.main.releaseVersionNumber ?? "").font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(aboutOn ? Color.notchAccent : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background { if aboutOn { SelectedRow(cornerRadius: 11, focused: showsFocus) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "About Underbrim"))
        .accessibilityAddTraits(aboutOn ? .isSelected : [])
    }

    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "Search"), text: $finder.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel(String(localized: "Search"))
                // Return opens the result picked on the right (↓ ↑ pick: SettingsResultsView); Escape clears.
                .onSubmit { finder.openSelection() }
                .onExitCommand { finder.query = "" }
            if !finder.query.isEmpty {
                Button { finder.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private var quit: some View {
        Button { NSApp.terminate(nil) } label: {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text("Quit Underbrim")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "⌘Q")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(SettingsPalette.hairline).frame(height: 1) }
    }

    private func row(_ tab: SettingsTab) -> some View {
        let on = tab == selection && !finder.isSearching
        return Button {
            finder.query = ""
            selection = tab
        } label: {
            HStack(spacing: 10) {
                tab.info.glyph
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color.notchAccent : SettingsPalette.glyph)
                    .frame(width: 22)
                // The whole width, not a Spacer after it, whose gap cost longer names 10 pt.
                Text(tab.title)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.white : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background { if on { SelectedRow(cornerRadius: 9, focused: showsFocus) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private struct SelectedRow: View {
        let cornerRadius: CGFloat
        /// The arrow keys move it: its edge in the accent, as a focus ring.
        let focused: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape.fill(.black)
                .overlay(shape.strokeBorder(focused ? Color.notchAccent : .white.opacity(0.08), lineWidth: focused ? 1.5 : 1))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
    }

    private func move(by step: Int) {
        let rows = [.about] + shown.flatMap(\.1).filter { $0 != .about }
        let index = rows.firstIndex(of: selection) ?? (step > 0 ? -1 : rows.count)
        selection = rows[min(max(index + step, 0), rows.count - 1)]
    }
}
