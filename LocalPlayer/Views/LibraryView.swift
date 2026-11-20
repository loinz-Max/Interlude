import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 长按锚点

private struct CardTarget: Equatable {
    let item: VideoItem
    let rect: CGRect
}

private struct FolderTarget: Equatable {
    let path: String
    let rect: CGRect
}

private enum LibraryPopup: Equatable {
    case importing
    case more
}

private struct CardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct FolderFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 「从文件导入」的选择器宿主。
///
/// 一个视图只该挂一个 presentation。`LibraryView` 身上已经有三个 `.sheet`
/// 加一串 `.alert`，再把 `.fileImporter` 也挂上去，等于四个呈现挤同一处——
/// SwiftUI 对这种写法没有定义，症状就是「点了不弹」或「选完回调不来」。
/// 这里把 importer 单独挂到一个看不见的子视图上，各走各的上下文。
private struct FileImportPresenter: View {
    @Binding var isPresented: Bool
    var onResult: (Result<[URL], Error>) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.movie, .video, .item],
                allowsMultipleSelection: true,
                onCompletion: onResult
            )
    }
}

// MARK: - 资料库

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var playingItem: VideoItem?
    /// 进播放页那一刻的列表顺序：冻结下来，切集时列表就不会把当前视频甩到末尾
    @State private var playingQueue: [VideoItem] = []
    /// 多选模式：由「⋯」菜单里的「全选」进入
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmBatchDelete = false
    @State private var batchMoving = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var showSettings = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    @State private var popup: LibraryPopup?
    @State private var target: CardTarget?
    @State private var folderTarget: FolderTarget?
    /// 长按刚触发时，同一串手势不要再被当成「点空白关闭」
    @State private var menuGuard = Date.distantPast
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var folderFrames: [String: CGRect] = [:]
    /// 清理缩略图缓存后递增：给列表挂 `.id`，逼它重建、重新取图。
    /// 视图不重建的话，`ThumbnailView` 里已经加载好的 `image` 会一直留着。
    @State private var refreshToken = 0

    @State private var renaming: VideoItem?
    @State private var renameText = ""
    @State private var deleting: VideoItem?

    @State private var renamingFolder: String?
    @State private var folderRenameText = ""
    @State private var deletingFolder: String?
    @State private var movingItem: VideoItem?

    @State private var toastText: String?
    @State private var toastToken = 0

    private let sidePadding: CGFloat = 16
    /// 长按浮起时的放大比例：原位置留空 + 轻微放大 + 投影，读作「这张被拎起来了」
    private static let liftScale: CGFloat = 1.09

    /// 浮层是按中心放大的，视觉边缘比原始 frame 各大出 (scale-1)/2，
    /// 菜单要按这个放大后的边缘让位，否则会贴在卡片上
    private func liftedRect(_ rect: CGRect) -> CGRect {
        let growth = (Self.liftScale - 1) / 2
        return rect.insetBy(dx: -rect.width * growth, dy: -rect.height * growth)
    }
    private let columnSpacing: CGFloat = 12
    private let rowSpacing: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                backgroundLayer

                VStack(spacing: 0) {
                    topBar
                    if library.currentFolder != nil { breadcrumb }
                    content
                }

                if popup != nil || target != nil || folderTarget != nil {
                    scrim
                }

                if let target {
                    floatingCard(target)
                    cardMenu(target, screen: proxy.size)
                }

                if let folderTarget {
                    floatingFolder(folderTarget)
                    folderMenu(folderTarget, screen: proxy.size)
                }

                if let currentPopup = popup {
                    switch currentPopup {
                    case .importing:
                        ImportMenu(
                            onPhoto: { popup = nil; showPhotoPicker = true },
                            onFile: { popup = nil; showFileImporter = true }
                        )
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, sidePadding)
                        .transition(.opacity)

                    case .more:
                        MoreMenu(
                            viewMode: settings.libraryView,
                            sortKey: settings.sortKey,
                            ascending: settings.sortAscending,
                            onSelectAll: {
                                popup = nil
                                enterSelectAll()
                            },
                            onCreateFolder: {
                                popup = nil
                                newFolderName = ""
                                showNewFolder = true
                            },
                            onViewMode: { mode in
                                settings.libraryView = mode
                                popup = nil
                            },
                            onNameSort: {
                                popup = nil
                                if settings.sortKey == .name {
                                    settings.sortAscending.toggle()
                                } else {
                                    settings.sortKey = .name
                                    settings.sortAscending = true
                                }
                            },
                            onDateSort: {
                                popup = nil
                                settings.sortKey = .added
                                settings.sortAscending = false
                            }
                        )
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, sidePadding)
                        .transition(.opacity)
                    }
                }

                toastView
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .coordinateSpace(name: "root")
            .animation(.easeOut(duration: 0.16), value: popup)
            // 长按浮层用带一点回弹的弹簧：卡片「被拎起来」再落定，比纯淡入更有实感
            .animation(.spring(response: 0.30, dampingFraction: 0.86), value: target)
            .animation(.spring(response: 0.30, dampingFraction: 0.86), value: folderTarget)
        }
        // 播放页走同层覆盖而不是 fullScreenCover：
        // 模态控制器会绕开 AppDelegate 的方向掩码，导致「只有播放页能转」。
        .overlay {
            if let item = playingItem {
                PlayerScreen(item: item, queue: playingQueue) {
                    withAnimation(.easeOut(duration: 0.18)) { playingItem = nil }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: playingItem?.id)
        // 设置页走同层覆盖：fullScreenCover 只能从下往上推，
        // 这里要的是「从左推入」，回来时顺原路退出。
        .overlay {
            if showSettings {
                SettingsView(onClose: { showSettings = false })
                    .transition(.move(edge: .leading))
                    .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.30), value: showSettings)
        // 画中画小窗点「展开」：把全屏播放页拉回来（横屏时转屏交给幕布）
        .onReceive(NotificationCenter.default.publisher(for: PiPService.restoreNotification)) { note in
            guard let item = note.userInfo?["item"] as? VideoItem else { return }
            let queue = (note.userInfo?["queue"] as? [VideoItem]) ?? [item]
            startPlaying(item, queue: queue)
        }
        // 在「文件」App 里长按视频选「用幕间打开」，或其它 App 的「用其他应用打开」：
        // 系统把文件 URL 交给 App，这里先收进缓冲区，再由视图取走导入。
        // 以前没有这条通路，文件送进来毫无反应——App 只是被拉起来，什么也没发生。
        .onOpenURL { url in
            OpenInbox.shared.receive(url)
        }
        .onReceive(OpenInbox.shared.objectWillChange) { _ in
            // 取走（会改状态）和导入都推到下一拍：
            // 这里还在视图更新过程中，直接改状态会触发紫色告警
            DispatchQueue.main.async { drainOpenInbox() }
        }
        // 设置里点了「清理缩略图缓存」：重建列表，让每张卡重新生成缩略图。
        // 不重建的话内存里的旧图还挂着，只有重启 App 才会变。
        .onReceive(NotificationCenter.default.publisher(for: ThumbnailLoader.clearedNotification)) { _ in
            refreshToken += 1
        }
        // 导入进度贴在底部，不铺遮罩：导入期间照样能滑、能点开视频。
        // 位置和 toast 一致，导入结束的汇总提示正好接在同一处。
        .overlay(alignment: .bottom) {
            if let importProgress = library.importProgress {
                ImportProgressHUD(progress: importProgress)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.22), value: library.importProgress == nil)
        .overlay(alignment: .bottom) {
            if selecting {
                selectionBar
            }
        }
        .onAppear {
            library.reload()
            progress.refresh()
            applyDebugRoute()
            // 冷启动被「用幕间打开」拉起来时，URL 往往在视图出现之前就到了，
            // 那时 onReceive 还没订阅上，只能在这里补一次
            drainOpenInbox()
        }
        .onChange(of: scenePhase) { _, phase in
            // 从爱思助手 / 文件 App / iCloud 拷完文件切回来，重新扫一遍
            guard phase == .active else { return }
            library.reload()
            progress.refresh()
        }
        // 文件选择器单独挂在看不见的子视图上，不和下面那串 sheet 抢同一个呈现上下文
        .background {
            FileImportPresenter(isPresented: $showFileImporter, onResult: handleFileImport)
        }
        .sheet(isPresented: $showPhotoPicker) {
            // 用 PHPicker 才能拿到相册里的原文件名
            PhotoPickerSheet { movies, failed in
                showPhotoPicker = false
                // 以前这里是 `guard !movies.isEmpty else { return }`：
                // 全部读失败时选择器一关，用户什么都看不到
                if movies.isEmpty {
                    toast(failed > 0 ? "\(failed) 个文件没能读取" : "没有取到可导入的视频")
                    return
                }
                importMovies(movies, failed: failed)
            }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                library.createFolder(newFolderName)
                newFolderName = ""
                toast("已创建文件夹")
            }
        }
        .alert("重命名", isPresented: renameBinding) {
            TextField("文件名", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { commitRename() }
        } message: {
            Text("会同时改磁盘上的文件名，扩展名保留")
        }
        .alert(
            "删除「\(deleting?.displayName ?? "")」？",
            isPresented: deleteBinding,
            presenting: deleting
        ) { item in
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                progress.forget(id: item.id)
                library.delete(item)
                deleting = nil
                toast("已删除")
            }
        } message: { _ in
            Text("文件会从本机移除，这个操作不能撤销。")
        }
        .alert("重命名文件夹", isPresented: folderRenameBinding) {
            TextField("显示名称", text: $folderRenameText)
            Button("取消", role: .cancel) { renamingFolder = nil }
            Button("保存") { commitFolderRename() }
        } message: {
            Text("只改显示名，磁盘上的目录名不变，里面的视频不受影响。")
        }
        .alert(
            "删除文件夹「\(deletingFolderName)」？",
            isPresented: folderDeleteBinding,
            presenting: deletingFolder
        ) { path in
            Button("取消", role: .cancel) { deletingFolder = nil }
            Button("删除", role: .destructive) { deleteSelectedFolder(path) }
        } message: { path in
            Text("文件夹里的 \(library.itemsInside(path).count) 个视频会一起从本机移除，这个操作不能撤销。")
        }
        .sheet(item: $movingItem) { item in
            MoveFolderSheet(
                subtitle: item.name,
                currentFolder: item.folder,
                choices: library.folderChoices
            ) { path in
                moveItem(item, to: path)
            }
        }
        .sheet(isPresented: $batchMoving) {
            MoveFolderSheet(
                subtitle: "已选 \(selection.count) 个视频",
                currentFolder: library.currentFolder ?? "",
                choices: library.folderChoices
            ) { path in
                batchMoving = false
                batchMove(to: path)
            }
        }
        .alert("删除选中的 \(selection.count) 个视频？", isPresented: $confirmBatchDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { batchDelete() }
        } message: {
            Text("文件会从本机移除，这个操作不能撤销。")
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        // 标题单独占一层固定在屏幕正中，不随两侧按钮数量偏移
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 92)

            HStack(spacing: 8) {
                GlassIconButton(systemName: "gearshape", size: 36, iconSize: 17) {
                    showSettings = true
                }

                Spacer(minLength: 0)

                GlassIconButton(systemName: "arrow.down.doc", size: 36, iconSize: 17) {
                    popup = popup == .importing ? nil : .importing
                }
                GlassIconButton(systemName: "ellipsis", size: 36, iconSize: 17) {
                    popup = popup == .more ? nil : .more
                }
            }
        }
        .padding(.horizontal, sidePadding)
        .frame(height: 54)
    }

    private var title: String {
        if selecting { return "已选 \(selection.count) 个" }
        guard let folder = library.currentFolder else { return "Interlude" }
        return library.displayName(forFolder: folder)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                library.currentFolder = nil
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Interlude")
                        .font(.system(size: 14))
                }
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, sidePadding)
        .padding(.bottom, 8)
    }

    // MARK: - 网格

    private var content: some View {
        Group {
            if library.subfolders.isEmpty && sortedVideos.isEmpty {
                emptyState
            } else if settings.libraryView == .list {
                videoList
            } else {
                grid
            }
        }
        .onPreferenceChange(CardFrameKey.self) { cardFrames = $0 }
        .onPreferenceChange(FolderFrameKey.self) { folderFrames = $0 }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: columnSpacing),
                    GridItem(.flexible(), spacing: columnSpacing)
                ],
                alignment: .leading,
                spacing: rowSpacing
            ) {
                ForEach(library.subfolders, id: \.self) { folder in
                    FolderCard(
                        name: library.displayName(forFolder: folder),
                        count: count(in: folder)
                    )
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: FolderFrameKey.self,
                                value: [folder: geo.frame(in: .named("root"))]
                            )
                        }
                    }
                    .onTapGesture {
                        if folderTarget != nil || target != nil {
                            if Date().timeIntervalSince(menuGuard) > 0.35 { closeMenus() }
                        } else {
                            library.currentFolder = folder
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.38) {
                        openFolderMenu(folder)
                    }
                    .opacity(folderTarget?.path == folder ? 0 : 1)
                }

                ForEach(sortedVideos) { item in
                    card(item)
                }
            }
            .id(refreshToken)
            .padding(.horizontal, sidePadding)
            .padding(.top, 14)
            .padding(.bottom, 40)
        }
        .refreshable {
            // 下拉兜底：文件系统监听万一没收到事件，手动也能拉一次。
            // 等扫描落地再收手，转圈的时间才和真正扫盘的时间对得上
            await library.reload().value
            progress.refresh()
        }
    }

    private func card(_ item: VideoItem) -> some View {
        VideoCard(
            item: item,
            fraction: progress.progressFraction(for: item.id),
            watched: progress.isWatched(item.id),
            active: target?.item.id == item.id,
            selected: selection.contains(item.id)
        )
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: CardFrameKey.self,
                    value: [item.id: geo.frame(in: .named("root"))]
                )
            }
        }
        .onTapGesture {
            if selecting {
                toggleSelection(item.id)
                return
            }
            if target != nil || folderTarget != nil {
                if Date().timeIntervalSince(menuGuard) > 0.35 { closeMenus() }
            } else {
                startPlaying(item, queue: sortedVideos)
            }
        }
        .onLongPressGesture(minimumDuration: 0.38) {
            if selecting {
                toggleSelection(item.id)
            } else {
                openCardMenu(item)
            }
        }
        // 浮层已经替代了它，原位留空，避免两张卡叠在一起露出错位边缘
        .opacity(target?.item.id == item.id ? 0 : 1)
    }

    // MARK: - 列表视图

    private var videoList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(library.subfolders, id: \.self) { folder in
                    folderRow(folder)
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, sidePadding + 108)
                }

                ForEach(sortedVideos) { item in
                    listRow(item)
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, sidePadding + 108)
                }
            }
            .id(refreshToken)
            .padding(.horizontal, sidePadding)
            .padding(.top, 8)
            .padding(.bottom, selecting ? 96 : 40)
        }
        .refreshable {
            await library.reload().value
            progress.refresh()
        }
    }

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.accent.opacity(0.9))
                }
                .frame(width: 96, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(library.displayName(forFolder: folder))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text("\(count(in: folder)) 个视频")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiaryText)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            if folderTarget != nil || target != nil {
                if Date().timeIntervalSince(menuGuard) > 0.35 { closeMenus() }
            } else {
                library.currentFolder = folder
            }
        }
        .onLongPressGesture(minimumDuration: 0.38) {
            openFolderMenu(folder)
        }
        .opacity(folderTarget?.path == folder ? 0 : 1)
    }

    private func listRow(_ item: VideoItem) -> some View {
        VideoRow(
            item: item,
            fraction: progress.progressFraction(for: item.id),
            watched: progress.isWatched(item.id),
            selected: selection.contains(item.id)
        )
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: CardFrameKey.self,
                    value: [item.id: geo.frame(in: .named("root"))]
                )
            }
        }
        .onTapGesture {
            if selecting {
                toggleSelection(item.id)
                return
            }
            if target != nil || folderTarget != nil {
                if Date().timeIntervalSince(menuGuard) > 0.35 { closeMenus() }
            } else {
                startPlaying(item, queue: sortedVideos)
            }
        }
        .onLongPressGesture(minimumDuration: 0.38) {
            if selecting {
                toggleSelection(item.id)
            } else {
                openCardMenu(item)
            }
        }
        // 浮层已经替代了它，原位留空，避免两张卡叠在一起露出错位边缘
        .opacity(target?.item.id == item.id ? 0 : 1)
    }

    // MARK: - 多选

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button {
                toggleSelectAll()
            } label: {
                Text(isAllSelected ? "取消全选" : "全选")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .glass(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                guard !selection.isEmpty else { return }
                batchMoving = true
            } label: {
                Text("移动")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .glass(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                guard !selection.isEmpty else { return }
                confirmBatchDelete = true
            } label: {
                Text("删除")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .glass(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                exitSelection()
            } label: {
                Text("完成")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, sidePadding)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func enterSelectAll() {
        withAnimation(.easeOut(duration: 0.16)) {
            selecting = true
            selection = Set(sortedVideos.map(\.id))
        }
    }

    private func exitSelection() {
        withAnimation(.easeOut(duration: 0.16)) {
            selecting = false
            selection.removeAll()
        }
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    /// 目录为空时 0 == 0 也算「全选」是错的：那时候一个都没选
    private var isAllSelected: Bool {
        !sortedVideos.isEmpty && selection.count == sortedVideos.count
    }

    private func toggleSelectAll() {
        if isAllSelected {
            selection.removeAll()
        } else {
            selection = Set(sortedVideos.map(\.id))
        }
    }

    private func batchDelete() {
        let victims = selection
        for id in victims { progress.forget(id: id) }
        let removed = library.deleteMany(ids: victims)
        exitSelection()
        toast(removed > 0 ? "已删除 \(removed) 个视频" : "删除失败")
    }

    private func batchMove(to path: String) {
        var moved = 0
        for id in selection {
            guard let item = library.allItems.first(where: { $0.id == id }) else { continue }
            let oldID = item.id
            if let newItem = library.move(item, to: path) {
                progress.renamePath(from: oldID, to: newItem.id)
                moved += 1
            }
        }
        exitSelection()
        let name = path.isEmpty ? "资料库" : library.displayName(forFolder: path)
        toast(moved > 0 ? "已移动 \(moved) 个视频到「\(name)」" : "没有移动任何文件")
    }

    private func count(in folder: String) -> Int {
        library.allItems.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }.count
    }

    // MARK: - 排序

    /// 文件夹排在前面，视频按当前排序规则（名称 / 日期）
    private var sortedVideos: [VideoItem] {
        let list = library.items
        let key = settings.sortKey
        let asc = settings.sortAscending

        return list.sorted { a, b in
            let forward: Bool
            switch key {
            case .name:
                forward = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .added:
                forward = a.modified > b.modified
            }
            return asc ? forward : !forward
        }
    }

    // MARK: - 长按菜单

    private var scrim: some View {
        Color.black.opacity(0.38)
            .ignoresSafeArea()
            .transition(.opacity)
            .onTapGesture {
                guard Date().timeIntervalSince(menuGuard) > 0.35 else { return }
                closeMenus()
                popup = nil
            }
    }

    /// 被长按的卡片浮在遮罩之上，保持清晰
    /// 被长按的卡片浮在遮罩之上：原位置留空，浮层从原尺寸放大到 1.06 并带投影
    private func floatingCard(_ target: CardTarget) -> some View {
        VideoCard(
            item: target.item,
            fraction: progress.progressFraction(for: target.item.id),
            watched: progress.isWatched(target.item.id),
            active: true,
            lifted: true
        )
        .frame(width: target.rect.width, alignment: .top)
        .scaleEffect(Self.liftScale)
        .position(x: target.rect.midX, y: target.rect.midY)
        .allowsHitTesting(false)
        .transition(.scale(scale: 1 / Self.liftScale).combined(with: .opacity))
    }

    private func floatingFolder(_ target: FolderTarget) -> some View {
        FolderCard(
            name: library.displayName(forFolder: target.path),
            count: count(in: target.path),
            lifted: true
        )
        .frame(width: target.rect.width, alignment: .top)
        .scaleEffect(Self.liftScale)
        .position(x: target.rect.midX, y: target.rect.midY)
        .allowsHitTesting(false)
        .transition(.scale(scale: 1 / Self.liftScale).combined(with: .opacity))
    }

    private func cardMenu(_ target: CardTarget, screen: CGSize) -> some View {
        let width = CardMenu.width
        let height = CardMenu.estimatedHeight
        let rect = liftedRect(target.rect)
        let x = min(max(sidePadding, rect.minX), max(sidePadding, screen.width - sidePadding - width))
        var y = rect.maxY + 8
        if y + height > screen.height - 16 {
            y = rect.minY - height - 8
        }
        y = max(16, y)

        return CardMenu(
            item: target.item,
            watched: progress.isWatched(target.item.id),
            onMarkWatched: {
                progress.setWatched(target.item.id, !progress.isWatched(target.item.id))
                closeCardMenu()
            },
            onRename: {
                renameText = target.item.displayName
                renaming = target.item
                closeCardMenu()
            },
            onMove: {
                movingItem = target.item
                closeCardMenu()
            },
            onDelete: {
                deleting = target.item
                closeCardMenu()
            }
        )
        .position(x: x + width / 2, y: y + height / 2)
        .transition(.opacity)
    }

    private func folderMenu(_ target: FolderTarget, screen: CGSize) -> some View {
        let width = FolderMenu.width
        let height = FolderMenu.estimatedHeight
        let rect = liftedRect(target.rect)
        let x = min(max(sidePadding, rect.minX), max(sidePadding, screen.width - sidePadding - width))
        var y = rect.maxY + 8
        if y + height > screen.height - 16 {
            y = rect.minY - height - 8
        }
        y = max(16, y)

        return FolderMenu(
            name: library.displayName(forFolder: target.path),
            onRename: {
                folderRenameText = library.displayName(forFolder: target.path)
                renamingFolder = target.path
                closeMenus()
            },
            onDelete: {
                deletingFolder = target.path
                closeMenus()
            }
        )
        .position(x: x + width / 2, y: y + height / 2)
        .transition(.opacity)
    }

    private func openCardMenu(_ item: VideoItem) {
        popup = nil
        folderTarget = nil
        menuGuard = Date()
        let rect = cardFrames[item.id] ?? .zero
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            target = CardTarget(item: item, rect: rect)
        }
    }

    private func openFolderMenu(_ path: String) {
        popup = nil
        target = nil
        menuGuard = Date()
        let rect = folderFrames[path] ?? .zero
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            folderTarget = FolderTarget(path: path, rect: rect)
        }
    }

    private func closeCardMenu() {
        withAnimation(.easeOut(duration: 0.14)) { target = nil }
    }

    /// 点开一个视频。设置成横屏、或手机正横握（跟随系统）时，进入播放页
    /// 会发生一次转屏——先拉转屏幕布把旋转遮住，再进播放页。
    private func startPlaying(_ item: VideoItem, queue: [VideoItem]) {
        let present = {
            playingQueue = queue
            withAnimation(.easeOut(duration: 0.18)) { playingItem = item }
        }
        let willRotate: Bool
        switch AppSettings.storedOrientation() {
        case .landscape: willRotate = true       // 强制横屏，怎么握都得转
        case .portrait:  willRotate = false      // 锁竖屏，永远不转
        case .system:    willRotate = OrientationCurtain.deviceIsLandscape
        }
        if willRotate {
            OrientationCurtain.shared.perform(.landscape, during: present)
        } else {
            present()
        }
    }

    private func closeMenus() {
        withAnimation(.easeOut(duration: 0.14)) {
            target = nil
            folderTarget = nil
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        // 空目录不放任何提示：留白就是提示
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 背景

    /// 纯黑背景上玻璃永远是黑的 —— 没有东西可透，材质就看不出层次。
    /// 顶部压一层极淡的白雾（2.8%），控件下面才有底色可模糊，整页也不至于死黑。
    private var backgroundLayer: some View {
        Palette.background
            .overlay {
                LinearGradient(
                    colors: [Color.white.opacity(0.028), .clear],
                    startPoint: .top,
                    endPoint: .init(x: 0.5, y: 0.42)
                )
            }
            .ignoresSafeArea()
    }

    // MARK: - 浮层

    @ViewBuilder
    private var toastView: some View {
        if let toastText {
            HUDLabel(text: toastText)
                .padding(.bottom, 28)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 绑定

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )
    }

    private var folderRenameBinding: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    private var folderDeleteBinding: Binding<Bool> {
        Binding(
            get: { deletingFolder != nil },
            set: { if !$0 { deletingFolder = nil } }
        )
    }

    private var deletingFolderName: String {
        guard let path = deletingFolder else { return "" }
        return library.displayName(forFolder: path)
    }

    // MARK: - 动作

    private func commitRename() {
        guard let item = renaming else { return }
        let oldID = item.id
        renaming = nil
        guard let renamed = library.rename(item, to: renameText) else {
            toast("重命名失败，可能有同名文件")
            return
        }
        progress.renamePath(from: oldID, to: renamed.id)
        toast("已重命名")
    }

    private func commitFolderRename() {
        guard let path = renamingFolder else { return }
        renamingFolder = nil
        library.renameFolder(path, to: folderRenameText)
        toast("已重命名")
    }

    private func deleteSelectedFolder(_ path: String) {
        let victims = library.itemsInside(path)
        for item in victims { progress.forget(id: item.id) }
        let removed = library.deleteFolder(path)
        if library.currentFolder == path { library.currentFolder = nil }
        deletingFolder = nil
        toast(removed > 0 ? "已删除文件夹（含 \(removed) 个视频）" : "已删除空文件夹")
    }

    private func moveItem(_ item: VideoItem, to path: String) {
        guard path != item.folder else { return }
        let oldID = item.id
        guard let moved = library.move(item, to: path) else {
            toast("移动失败，目标里可能有同名文件")
            return
        }
        progress.renamePath(from: oldID, to: moved.id)
        let name = path.isEmpty ? "资料库" : library.displayName(forFolder: path)
        toast("已移到「\(name)」")
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task {
                let outcome = await library.importItems(urls.map { ImportItem(url: $0) })
                toast(outcome.summary)
            }
        case .failure:
            toast("导入失败")
        }
    }

    /// 「用幕间打开」送进来的文件：导入当前目录；只有一个文件、系统能直接播时顺手播它
    private func drainOpenInbox() {
        let urls = OpenInbox.shared.take()
        guard !urls.isEmpty else { return }
        Task {
            let outcome = await library.importItems(urls.map { ImportItem(url: $0) })
            toast(outcome.summary)

            // 用户点「用幕间打开」就是为了看这个文件，导入完直接进播放页。
            // 多选、格式不支持（mkv 之类）、或当前已经在看别的片，都不打断。
            guard urls.count == 1,
                  let saved = outcome.saved.first,
                  let item = VideoItem(url: saved, documents: library.documents),
                  item.systemPlayable,
                  playingItem == nil else { return }
            let queue = sortedVideos.contains { $0.id == item.id } ? sortedVideos : [item]
            startPlaying(item, queue: queue)
        }
    }

    private func importMovies(_ movies: [PickedMovie], failed: Int = 0) {
        guard !movies.isEmpty else { return }
        Task {
            let outcome = await library.importItems(
                movies.map { ImportItem(url: $0.url, preferredName: $0.name, moving: true) }
            )
            // 读取阶段就失败的那几个也要说出来，否则「选了 5 个只进来 3 个」没法解释
            toast(failed > 0 ? "\(outcome.summary)，\(failed) 个没能读取" : outcome.summary)
        }
    }

    private func toast(_ text: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.15)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) { toastText = nil }
            }
        }
    }

    // MARK: - 调试直达

    #if DEBUG
    /// 截图用：给前几个视频写一点进度，用来核对角标
    private func seedDebugProgressIfNeeded() {
        guard DebugSeed.argument(after: "-seedProgress") == "1" else { return }
        let items = library.allItems.filter { $0.folder.isEmpty }
        guard items.count >= 3 else { return }
        progress.update(id: items[0].id, time: 3.4, total: 8)
        progress.update(id: items[1].id, time: 6.2, total: 8)
        progress.setWatched(items[2].id, true)
    }
    #endif

    private func applyDebugRoute() {
        #if DEBUG
        seedDebugProgressIfNeeded()
        guard let route = DebugSeed.argument(after: "-screen") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            switch route {
            case "player":
                if let first = library.allItems.first {
                    if !first.folder.isEmpty { library.currentFolder = first.folder }
                    playingQueue = sortedVideos
                    playingItem = first
                }
            case "folder":
                if let first = library.subfolders.first { library.currentFolder = first }
            case "settings":
                showSettings = true
            case "foldermenu":
                // 等卡片布局完成、folderFrames 有值之后再弹菜单，否则锚点是 .zero
                if let first = library.subfolders.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        openFolderMenu(first)
                    }
                }
            case "cardmenu":
                // 视频卡片的长按菜单（缩略图浮起的另一种形态）
                if let first = library.allItems.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        openCardMenu(first)
                    }
                }
            case "list":
                settings.libraryView = .list
            case "select":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { enterSelectAll() }
            case "more":
                popup = .more
            case "move":
                if let first = library.allItems.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        movingItem = first
                    }
                }
            default:
                break
            }
        }
        #endif
    }
}
