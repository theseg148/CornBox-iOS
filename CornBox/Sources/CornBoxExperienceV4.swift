import SwiftUI
import UIKit
import AVFoundation

// CornBox V4: the old HTML is the design reference; UIKit/AVFoundation are the engine.

struct RootViewV4: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { CBXTabController(store: .shared) }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

enum CBXTheme {
    static let ink = UIColor(red: 0.055, green: 0.047, blue: 0.075, alpha: 1)
    static let panel = UIColor(red: 0.105, green: 0.086, blue: 0.135, alpha: 1)
    static let grape = UIColor(red: 0.52, green: 0.30, blue: 0.96, alpha: 1)
    static let peach = UIColor(red: 1.0, green: 0.47, blue: 0.35, alpha: 1)
    static let cream = UIColor(red: 1.0, green: 0.94, blue: 0.84, alpha: 1)
    static let mint = UIColor(red: 0.36, green: 0.90, blue: 0.70, alpha: 1)
}

final class CBXTabController: UITabBarController, UITabBarControllerDelegate {
    let store: CornBoxStore
    let feed: CBXFeedController
    let library: CBXLibraryController
    let creators: CBXCreatorsController
    let activity: CBXActivityController
    let addDummy = UIViewController()

    init(store: CornBoxStore) {
        self.store = store
        feed = CBXFeedController(store: store)
        library = CBXLibraryController(store: store)
        creators = CBXCreatorsController(store: store)
        activity = CBXActivityController(store: store)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.backgroundColor = CBXTheme.ink
        let home = UINavigationController(rootViewController: feed); home.setNavigationBarHidden(true, animated: false)
        let lib = UINavigationController(rootViewController: library)
        let act = UINavigationController(rootViewController: activity)
        let people = UINavigationController(rootViewController: creators)
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "sparkles.tv.fill"), tag: 0)
        lib.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "rectangle.stack.fill"), tag: 1)
        addDummy.tabBarItem = UITabBarItem(title: "Add", image: UIImage(systemName: "plus.circle.fill"), tag: 2)
        act.tabBarItem = UITabBarItem(title: "Activity", image: UIImage(systemName: "bolt.heart.fill"), tag: 3)
        people.tabBarItem = UITabBarItem(title: "Creators", image: UIImage(systemName: "person.2.crop.square.stack.fill"), tag: 4)
        viewControllers = [home, lib, addDummy, act, people]

        let a = UITabBarAppearance(); a.configureWithOpaqueBackground(); a.backgroundColor = CBXTheme.ink
        a.shadowColor = CBXTheme.grape.withAlphaComponent(0.35)
        a.stackedLayoutAppearance.normal.iconColor = .systemGray2
        a.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.systemGray2]
        a.stackedLayoutAppearance.selected.iconColor = CBXTheme.cream
        a.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: CBXTheme.cream]
        tabBar.standardAppearance = a; tabBar.scrollEdgeAppearance = a; tabBar.tintColor = CBXTheme.cream

        let nav = UINavigationBarAppearance(); nav.configureWithOpaqueBackground(); nav.backgroundColor = CBXTheme.ink
        nav.titleTextAttributes = [.foregroundColor: CBXTheme.cream]
        nav.largeTitleTextAttributes = [.foregroundColor: CBXTheme.cream, .font: UIFont.systemFont(ofSize: 34, weight: .black)]
        UINavigationBar.appearance().standardAppearance = nav; UINavigationBar.appearance().scrollEdgeAppearance = nav

        store.onChange = { [weak self] in
            self?.feed.reloadKeepingPlace(); self?.library.reload(); self?.creators.reload(); self?.activity.reload()
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === addDummy { presentAdd(); return false }
        return true
    }

    func showMedia(_ id: String) { selectedIndex = 0; feed.open(id) }

    private func presentAdd() {
        let s = UIAlertController(title: "Feed the box", message: "Pick where your media lives.", preferredStyle: .actionSheet)
        s.addAction(UIAlertAction(title: "Photos", style: .default) { _ in self.presentPicker() })
        s.addAction(UIAlertAction(title: "Files", style: .default) { _ in self.presentPicker() })
        s.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(s, animated: true)
    }
    private func presentPicker() {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .image], asCopy: true); p.allowsMultipleSelection = true
        p.delegate = self; present(p, animated: true)
    }
}

extension CBXTabController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        store.importFiles(urls) { }
    }
}

final class CBXFeedController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    let store: CornBoxStore
    var items: [CBMedia]
    var currentID: String?
    let layout = UICollectionViewFlowLayout()
    lazy var cv = UICollectionView(frame: .zero, collectionViewLayout: layout)

    init(store: CornBoxStore) { self.store = store; items = store.media; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = CBXTheme.ink
        layout.scrollDirection = .vertical; layout.minimumLineSpacing = 0
        cv.backgroundColor = CBXTheme.ink; cv.isPagingEnabled = true; cv.alwaysBounceVertical = false
        cv.showsVerticalScrollIndicator = false; cv.contentInsetAdjustmentBehavior = .never
        cv.dataSource = self; cv.delegate = self; cv.register(CBXFeedCell.self, forCellWithReuseIdentifier: "feed")
        cv.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(cv)
        NSLayoutConstraint.activate([cv.leadingAnchor.constraint(equalTo:view.leadingAnchor),cv.trailingAnchor.constraint(equalTo:view.trailingAnchor),cv.topAnchor.constraint(equalTo:view.topAnchor),cv.bottomAnchor.constraint(equalTo:view.bottomAnchor)])

        let badge = CBXPill(); badge.text = "✦  FOR YOU"; badge.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(badge)
        let shuffle = UIButton(type:.system); shuffle.setImage(UIImage(systemName:"shuffle"), for:.normal); shuffle.tintColor = CBXTheme.cream
        shuffle.backgroundColor = CBXTheme.panel.withAlphaComponent(0.9); shuffle.layer.cornerRadius = 19; shuffle.addTarget(self, action:#selector(shuffleNow), for:.touchUpInside)
        shuffle.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(shuffle)
        NSLayoutConstraint.activate([badge.centerXAnchor.constraint(equalTo:view.centerXAnchor),badge.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),shuffle.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),shuffle.centerYAnchor.constraint(equalTo:badge.centerYAnchor),shuffle.widthAnchor.constraint(equalToConstant:38),shuffle.heightAnchor.constraint(equalToConstant:38)])
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); let s=cv.bounds.size; if layout.itemSize != s { layout.itemSize=s; layout.invalidateLayout() } }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); playCenter() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); cv.visibleCells.compactMap{$0 as? CBXFeedCell}.forEach{$0.pause()} }

    func collectionView(_ collectionView:UICollectionView, numberOfItemsInSection section:Int)->Int { items.count }
    func collectionView(_ collectionView:UICollectionView, cellForItemAt indexPath:IndexPath)->UICollectionViewCell {
        let c=collectionView.dequeueReusableCell(withReuseIdentifier:"feed",for:indexPath) as! CBXFeedCell; let m=items[indexPath.item]
        c.configure(m, creator:store.creator(for:m), liked:store.isLiked(m.id)); c.onLike={ [weak self] in self?.store.toggleLike(m.id) }; return c
    }
    func collectionView(_ collectionView:UICollectionView, willDisplay cell:UICollectionViewCell, forItemAt indexPath:IndexPath) { (cell as? CBXFeedCell)?.loadPlayer(items[indexPath.item]) }
    func collectionView(_ collectionView:UICollectionView, didEndDisplaying cell:UICollectionViewCell, forItemAt indexPath:IndexPath) { (cell as? CBXFeedCell)?.releasePlayer() }
    func scrollViewWillBeginDragging(_ scrollView:UIScrollView){ cv.visibleCells.compactMap{$0 as? CBXFeedCell}.forEach{$0.pause()} }
    func scrollViewDidEndDecelerating(_ scrollView:UIScrollView){ playCenter() }
    func scrollViewDidEndScrollingAnimation(_ scrollView:UIScrollView){ playCenter() }

    func reloadKeepingPlace(){ currentID=centerItem()?.id ?? currentID; items=store.media; cv.reloadData(); if let id=currentID,let i=items.firstIndex(where:{$0.id==id}) { cv.layoutIfNeeded(); cv.scrollToItem(at:IndexPath(item:i,section:0),at:.top,animated:false) } }
    func open(_ id:String){ items=store.media; cv.reloadData(); cv.layoutIfNeeded(); if let i=items.firstIndex(where:{$0.id==id}) { currentID=id; cv.scrollToItem(at:IndexPath(item:i,section:0),at:.top,animated:false); DispatchQueue.main.async{self.playCenter()} } }
    @objc func shuffleNow(){ items.shuffle(); currentID=items.first?.id; cv.reloadData(); cv.setContentOffset(.zero,animated:false); DispatchQueue.main.async{self.playCenter()} }
    func centerItem()->CBMedia? { let p=CGPoint(x:cv.bounds.midX+cv.contentOffset.x,y:cv.bounds.midY+cv.contentOffset.y); guard let i=cv.indexPathForItem(at:p),i.item<items.count else{return nil}; return items[i.item] }
    func playCenter(){ let p=CGPoint(x:cv.bounds.midX+cv.contentOffset.x,y:cv.bounds.midY+cv.contentOffset.y); guard let i=cv.indexPathForItem(at:p) else{return}; currentID=items[i.item].id; for case let c as CBXFeedCell in cv.visibleCells { if cv.indexPath(for:c)==i { c.play() } else { c.pause() } } }
}

final class CBXFeedCell: UICollectionViewCell {
    var onLike:(()->Void)?; let playerSurface=CBXPlayerSurface(); let image=UIImageView(); let info=UIView(); let avatar=UIImageView(); let name=UILabel(); let handle=UILabel(); let filename=UILabel(); let like=UIButton(type:.system); let progress=UISlider(); var player:AVPlayer?; var observer:Any?; var itemID:String?
    override init(frame:CGRect){ super.init(frame:frame); backgroundColor=CBXTheme.ink; clipsToBounds=true
        playerSurface.translatesAutoresizingMaskIntoConstraints=false; addSubview(playerSurface); image.translatesAutoresizingMaskIntoConstraints=false; image.contentMode=.scaleAspectFit; image.backgroundColor=CBXTheme.ink; addSubview(image)
        info.backgroundColor=CBXTheme.panel.withAlphaComponent(0.82); info.layer.cornerRadius=22; info.layer.borderWidth=1; info.layer.borderColor=CBXTheme.grape.withAlphaComponent(0.45).cgColor; info.translatesAutoresizingMaskIntoConstraints=false; addSubview(info)
        avatar.layer.cornerRadius=25; avatar.clipsToBounds=true; avatar.contentMode=.scaleAspectFill; avatar.layer.borderWidth=2; avatar.layer.borderColor=CBXTheme.peach.cgColor; avatar.translatesAutoresizingMaskIntoConstraints=false
        name.textColor=CBXTheme.cream; name.font=.systemFont(ofSize:16,weight:.black); handle.textColor=CBXTheme.mint; handle.font=.systemFont(ofSize:12,weight:.bold); filename.textColor=.white.withAlphaComponent(0.7); filename.font=.systemFont(ofSize:11,weight:.medium); filename.numberOfLines=1
        let texts=UIStackView(arrangedSubviews:[name,handle,filename]); texts.axis=.vertical; texts.spacing=2; let row=UIStackView(arrangedSubviews:[avatar,texts]); row.axis=.horizontal; row.alignment=.center; row.spacing=10; row.translatesAutoresizingMaskIntoConstraints=false; info.addSubview(row)
        like.tintColor=CBXTheme.cream; like.backgroundColor=CBXTheme.panel.withAlphaComponent(0.88); like.layer.cornerRadius=24; like.addTarget(self,action:#selector(likeTap),for:.touchUpInside); like.translatesAutoresizingMaskIntoConstraints=false; addSubview(like)
        progress.minimumTrackTintColor=CBXTheme.peach; progress.maximumTrackTintColor=UIColor.white.withAlphaComponent(0.2); progress.setThumbImage(UIImage(),for:.normal); progress.addTarget(self,action:#selector(scrub(_:)),for:.valueChanged); progress.translatesAutoresizingMaskIntoConstraints=false; addSubview(progress)
        NSLayoutConstraint.activate([playerSurface.leadingAnchor.constraint(equalTo:leadingAnchor),playerSurface.trailingAnchor.constraint(equalTo:trailingAnchor),playerSurface.topAnchor.constraint(equalTo:topAnchor),playerSurface.bottomAnchor.constraint(equalTo:bottomAnchor),image.leadingAnchor.constraint(equalTo:leadingAnchor),image.trailingAnchor.constraint(equalTo:trailingAnchor),image.topAnchor.constraint(equalTo:topAnchor),image.bottomAnchor.constraint(equalTo:bottomAnchor),info.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),info.bottomAnchor.constraint(equalTo:safeAreaLayoutGuide.bottomAnchor,constant:-22),info.trailingAnchor.constraint(equalTo:like.leadingAnchor,constant:-10),row.leadingAnchor.constraint(equalTo:info.leadingAnchor,constant:12),row.trailingAnchor.constraint(equalTo:info.trailingAnchor,constant:-12),row.topAnchor.constraint(equalTo:info.topAnchor,constant:10),row.bottomAnchor.constraint(equalTo:info.bottomAnchor,constant:-10),avatar.widthAnchor.constraint(equalToConstant:50),avatar.heightAnchor.constraint(equalToConstant:50),like.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-16),like.bottomAnchor.constraint(equalTo:safeAreaLayoutGuide.bottomAnchor,constant:-28),like.widthAnchor.constraint(equalToConstant:48),like.heightAnchor.constraint(equalToConstant:48),progress.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),progress.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),progress.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-2),progress.heightAnchor.constraint(equalToConstant:18)])
    }
    required init?(coder:NSCoder){fatalError()}
    override func prepareForReuse(){super.prepareForReuse();releasePlayer();image.image=nil;onLike=nil}
    func configure(_ m:CBMedia,creator:CBCreator?,liked:Bool){itemID=m.id;name.text=creator?.name ?? "Unassigned";handle.text=creator?.handle ?? "tap Creators to organize";filename.text=m.name;avatar.image=CBXAvatar.make(creator?.photo,name:creator?.name ?? "?");like.setImage(UIImage(systemName:liked ? "heart.fill":"heart"),for:.normal);like.tintColor=liked ? CBXTheme.peach:CBXTheme.cream; if m.kind == .image { playerSurface.isHidden=true;image.isHidden=false;image.image=UIImage(contentsOfFile:m.url.path);progress.isHidden=true } else {playerSurface.isHidden=false;image.isHidden=true;progress.isHidden=false}}
    func loadPlayer(_ m:CBMedia){guard m.kind == .video,itemID==m.id,player==nil else{return}; let asset=AVURLAsset(url:m.url); let pi=AVPlayerItem(asset:asset); pi.preferredForwardBufferDuration=5; let p=AVPlayer(playerItem:pi); p.automaticallyWaitsToMinimizeStalling=true; player=p;playerSurface.player=p; observer=p.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.12,preferredTimescale:600),queue:.main){[weak self,weak p] t in guard let self,let p,let d=p.currentItem?.duration.seconds,d.isFinite,d>0 else{return}; self.progress.value=Float(t.seconds/d)} }
    func play(){ if player==nil { return }; player?.play() }
    func pause(){player?.pause()}
    func releasePlayer(){if let o=observer,let p=player{p.removeTimeObserver(o)};observer=nil;player?.pause();player?.replaceCurrentItem(with:nil);playerSurface.player=nil;player=nil}
    @objc func likeTap(){onLike?()}
    @objc func scrub(_ s:UISlider){guard let d=player?.currentItem?.duration.seconds,d.isFinite else{return};player?.seek(to:CMTime(seconds:Double(s.value)*d,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)}
}

final class CBXPlayerSurface:UIView { override static var layerClass:AnyClass{AVPlayerLayer.self}; var layerPlayer:AVPlayerLayer{layer as! AVPlayerLayer}; var player:AVPlayer?{get{layerPlayer.player}set{layerPlayer.player=newValue}}; override init(frame:CGRect){super.init(frame:frame);layerPlayer.videoGravity=.resizeAspect;backgroundColor=CBXTheme.ink};required init?(coder:NSCoder){fatalError()} }
final class CBXPill:UILabel { override init(frame:CGRect){super.init(frame:frame);textColor=CBXTheme.cream;backgroundColor=CBXTheme.grape.withAlphaComponent(0.72);font=.systemFont(ofSize:12,weight:.black);textAlignment=.center;layer.cornerRadius=15;clipsToBounds=true};required init?(coder:NSCoder){fatalError()};override var intrinsicContentSize:CGSize{let s=super.intrinsicContentSize;return CGSize(width:s.width+24,height:30)} }

enum CBXAvatar { static func make(_ dataURL:String?,name:String)->UIImage { if let x=dataURL,let comma=x.firstIndex(of:","),let d=Data(base64Encoded:String(x[x.index(after:comma)...])),let i=UIImage(data:d){return i}; let r=UIGraphicsImageRenderer(size:CGSize(width:120,height:120));return r.image{c in CBXTheme.grape.setFill();c.fill(CGRect(x:0,y:0,width:120,height:120));let t=String(name.prefix(1)).uppercased();let a:[NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:50,weight:.black),.foregroundColor:CBXTheme.cream];let s=t.size(withAttributes:a);t.draw(at:CGPoint(x:(120-s.width)/2,y:(120-s.height)/2),withAttributes:a)} } }

final class CBXCreatorsController:UIViewController,UICollectionViewDataSource,UICollectionViewDelegateFlowLayout {
    let store:CornBoxStore; let layout=UICollectionViewFlowLayout(); lazy var cv=UICollectionView(frame:.zero,collectionViewLayout:layout)
    init(store:CornBoxStore){self.store=store;super.init(nibName:nil,bundle:nil);title="Creators"} required init?(coder:NSCoder){fatalError()}
    override func viewDidLoad(){super.viewDidLoad();view.backgroundColor=CBXTheme.ink;navigationController?.navigationBar.prefersLargeTitles=true;layout.minimumInteritemSpacing=12;layout.minimumLineSpacing=16;layout.sectionInset=UIEdgeInsets(top:14,left:14,bottom:30,right:14);cv.backgroundColor=CBXTheme.ink;cv.dataSource=self;cv.delegate=self;cv.register(CBXCreatorCard.self,forCellWithReuseIdentifier:"creator");cv.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(cv);NSLayoutConstraint.activate([cv.leadingAnchor.constraint(equalTo:view.leadingAnchor),cv.trailingAnchor.constraint(equalTo:view.trailingAnchor),cv.topAnchor.constraint(equalTo:view.topAnchor),cv.bottomAnchor.constraint(equalTo:view.bottomAnchor)])}
    func reload(){if isViewLoaded{cv.reloadData()}};func collectionView(_ c:UICollectionView,numberOfItemsInSection s:Int)->Int{store.creators.count};func collectionView(_ c:UICollectionView,layout:UICollectionViewLayout,sizeForItemAt i:IndexPath)->CGSize{let w=(c.bounds.width-40)/2;return CGSize(width:w,height:w*1.12)}
    func collectionView(_ c:UICollectionView,cellForItemAt i:IndexPath)->UICollectionViewCell{let x=c.dequeueReusableCell(withReuseIdentifier:"creator",for:i) as! CBXCreatorCard;x.configure(store.creators[i.item],count:store.creatorCount(store.creators[i.item].id));return x}
    func collectionView(_ c:UICollectionView,didSelectItemAt i:IndexPath){navigationController?.pushViewController(CBXCreatorProfile(store:store,creator:store.creators[i.item]),animated:true)}
}

final class CBXCreatorCard:UICollectionViewCell { let avatar=UIImageView();let name=UILabel();let handle=UILabel();let count=UILabel();override init(frame:CGRect){super.init(frame:frame);backgroundColor=CBXTheme.panel;layer.cornerRadius=24;layer.borderWidth=1;layer.borderColor=CBXTheme.grape.withAlphaComponent(0.5).cgColor;avatar.contentMode=.scaleAspectFill;avatar.clipsToBounds=true;avatar.translatesAutoresizingMaskIntoConstraints=false;name.textColor=CBXTheme.cream;name.font=.systemFont(ofSize:17,weight:.black);name.textAlignment=.center;handle.textColor=CBXTheme.mint;handle.font=.systemFont(ofSize:11,weight:.bold);handle.textAlignment=.center;count.textColor=.white.withAlphaComponent(0.55);count.font=.systemFont(ofSize:10,weight:.semibold);count.textAlignment=.center;let st=UIStackView(arrangedSubviews:[avatar,name,handle,count]);st.axis=.vertical;st.spacing=4;st.translatesAutoresizingMaskIntoConstraints=false;addSubview(st);NSLayoutConstraint.activate([st.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),st.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),st.topAnchor.constraint(equalTo:topAnchor,constant:12),st.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-12),avatar.heightAnchor.constraint(equalTo:avatar.widthAnchor)] )}required init?(coder:NSCoder){fatalError()};override func layoutSubviews(){super.layoutSubviews();avatar.layer.cornerRadius=avatar.bounds.width/2;avatar.layer.borderWidth=3;avatar.layer.borderColor=CBXTheme.peach.cgColor}func configure(_ c:CBCreator,count n:Int){avatar.image=CBXAvatar.make(c.photo,name:c.name);name.text=c.name;handle.text=c.handle;count.text="\(n) POSTS  ✦"} }

final class CBXCreatorProfile:UIViewController,UICollectionViewDataSource,UICollectionViewDelegateFlowLayout { let store:CornBoxStore;let creator:CBCreator;var media:[CBMedia];let header=UIView();let avatar=UIImageView();let name=UILabel();let handle=UILabel();let bio=UILabel();let stats=UILabel();let layout=UICollectionViewFlowLayout();lazy var cv=UICollectionView(frame:.zero,collectionViewLayout:layout)
    init(store:CornBoxStore,creator:CBCreator){self.store=store;self.creator=creator;self.media=store.media.filter{$0.creatorID==creator.id};super.init(nibName:nil,bundle:nil);title=creator.name}required init?(coder:NSCoder){fatalError()}
    override func viewDidLoad(){super.viewDidLoad();view.backgroundColor=CBXTheme.ink;header.backgroundColor=CBXTheme.panel;header.layer.cornerRadius=28;header.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(header);avatar.image=CBXAvatar.make(creator.photo,name:creator.name);avatar.contentMode=.scaleAspectFill;avatar.clipsToBounds=true;avatar.layer.cornerRadius=46;avatar.layer.borderWidth=3;avatar.layer.borderColor=CBXTheme.peach.cgColor;avatar.translatesAutoresizingMaskIntoConstraints=false;name.text=creator.name;name.textColor=CBXTheme.cream;name.font=.systemFont(ofSize:25,weight:.black);handle.text=creator.handle;handle.textColor=CBXTheme.mint;handle.font=.systemFont(ofSize:13,weight:.bold);bio.text=creator.bio;bio.textColor=.white.withAlphaComponent(0.8);bio.font=.systemFont(ofSize:13);bio.numberOfLines=3;stats.text="\(media.count) posts  •  \(media.filter{$0.kind == .video}.count) videos  •  \(media.filter{$0.kind == .image}.count) photos";stats.textColor=CBXTheme.peach;stats.font=.systemFont(ofSize:12,weight:.bold);let tx=UIStackView(arrangedSubviews:[name,handle,bio,stats]);tx.axis=.vertical;tx.spacing=4;tx.translatesAutoresizingMaskIntoConstraints=false;header.addSubview(avatar);header.addSubview(tx);layout.minimumLineSpacing=2;layout.minimumInteritemSpacing=2;cv.backgroundColor=CBXTheme.ink;cv.dataSource=self;cv.delegate=self;cv.register(CBXThumb.self,forCellWithReuseIdentifier:"thumb");cv.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(cv);NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),header.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),header.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),avatar.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:16),avatar.topAnchor.constraint(equalTo:header.topAnchor,constant:16),avatar.widthAnchor.constraint(equalToConstant:92),avatar.heightAnchor.constraint(equalToConstant:92),avatar.bottomAnchor.constraint(lessThanOrEqualTo:header.bottomAnchor,constant:-16),tx.leadingAnchor.constraint(equalTo:avatar.trailingAnchor,constant:14),tx.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-14),tx.centerYAnchor.constraint(equalTo:avatar.centerYAnchor),cv.leadingAnchor.constraint(equalTo:view.leadingAnchor),cv.trailingAnchor.constraint(equalTo:view.trailingAnchor),cv.topAnchor.constraint(equalTo:header.bottomAnchor,constant:12),cv.bottomAnchor.constraint(equalTo:view.bottomAnchor)])}
    func collectionView(_ c:UICollectionView,numberOfItemsInSection s:Int)->Int{media.count};func collectionView(_ c:UICollectionView,layout:UICollectionViewLayout,sizeForItemAt i:IndexPath)->CGSize{let w=(c.bounds.width-4)/3;return CGSize(width:w,height:w*1.35)};func collectionView(_ c:UICollectionView,cellForItemAt i:IndexPath)->UICollectionViewCell{let x=c.dequeueReusableCell(withReuseIdentifier:"thumb",for:i) as! CBXThumb;x.configure(media[i.item]);return x};func collectionView(_ c:UICollectionView,didSelectItemAt i:IndexPath){(tabBarController as? CBXTabController)?.showMedia(media[i.item].id)} }

final class CBXLibraryController:UIViewController,UICollectionViewDataSource,UICollectionViewDelegateFlowLayout {let store:CornBoxStore;let layout=UICollectionViewFlowLayout();lazy var cv=UICollectionView(frame:.zero,collectionViewLayout:layout);init(store:CornBoxStore){self.store=store;super.init(nibName:nil,bundle:nil);title="Library"}required init?(coder:NSCoder){fatalError()}override func viewDidLoad(){super.viewDidLoad();view.backgroundColor=CBXTheme.ink;navigationController?.navigationBar.prefersLargeTitles=true;layout.minimumLineSpacing=2;layout.minimumInteritemSpacing=2;cv.backgroundColor=CBXTheme.ink;cv.dataSource=self;cv.delegate=self;cv.register(CBXThumb.self,forCellWithReuseIdentifier:"thumb");cv.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(cv);NSLayoutConstraint.activate([cv.leadingAnchor.constraint(equalTo:view.leadingAnchor),cv.trailingAnchor.constraint(equalTo:view.trailingAnchor),cv.topAnchor.constraint(equalTo:view.topAnchor),cv.bottomAnchor.constraint(equalTo:view.bottomAnchor)])}func reload(){if isViewLoaded{cv.reloadData()}}func collectionView(_ c:UICollectionView,numberOfItemsInSection s:Int)->Int{store.media.count}func collectionView(_ c:UICollectionView,layout:UICollectionViewLayout,sizeForItemAt i:IndexPath)->CGSize{let w=(c.bounds.width-4)/3;return CGSize(width:w,height:w*1.35)}func collectionView(_ c:UICollectionView,cellForItemAt i:IndexPath)->UICollectionViewCell{let x=c.dequeueReusableCell(withReuseIdentifier:"thumb",for:i) as! CBXThumb;x.configure(store.media[i.item]);return x}func collectionView(_ c:UICollectionView,didSelectItemAt i:IndexPath){(tabBarController as? CBXTabController)?.showMedia(store.media[i.item].id)} }

final class CBXThumb:UICollectionViewCell {let image=UIImageView();let play=UIImageView(image:UIImage(systemName:"play.fill"));var token=UUID();override init(frame:CGRect){super.init(frame:frame);backgroundColor=CBXTheme.panel;image.contentMode=.scaleAspectFill;image.clipsToBounds=true;image.translatesAutoresizingMaskIntoConstraints=false;addSubview(image);play.tintColor=.white;play.translatesAutoresizingMaskIntoConstraints=false;addSubview(play);NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:leadingAnchor),image.trailingAnchor.constraint(equalTo:trailingAnchor),image.topAnchor.constraint(equalTo:topAnchor),image.bottomAnchor.constraint(equalTo:bottomAnchor),play.centerXAnchor.constraint(equalTo:centerXAnchor),play.centerYAnchor.constraint(equalTo:centerYAnchor)])}required init?(coder:NSCoder){fatalError()}override func prepareForReuse(){super.prepareForReuse();token=UUID();image.image=nil}func configure(_ m:CBMedia){play.isHidden=m.kind != .video;if m.kind == .image{image.image=UIImage(contentsOfFile:m.url.path)}else{let t=UUID();token=t;let asset=AVURLAsset(url:m.url);let g=AVAssetImageGenerator(asset:asset);g.appliesPreferredTrackTransform=true;g.maximumSize=CGSize(width:420,height:700);DispatchQueue.global(qos:.utility).async{let cg=try? g.copyCGImage(at:CMTime(seconds:0.1,preferredTimescale:600),actualTime:nil);let ui=cg.map{UIImage(cgImage:$0)};DispatchQueue.main.async{if self.token==t{self.image.image=ui}}}}} }

final class CBXActivityController:UITableViewController {let store:CornBoxStore;var items:[CBActivity]=[];init(store:CornBoxStore){self.store=store;super.init(style:.insetGrouped);title="Activity"}required init?(coder:NSCoder){fatalError()}override func viewDidLoad(){super.viewDidLoad();tableView.backgroundColor=CBXTheme.ink;navigationController?.navigationBar.prefersLargeTitles=true;reload()}func reload(){items=store.activities();if isViewLoaded{tableView.reloadData()}}override func tableView(_ t:UITableView,numberOfRowsInSection s:Int)->Int{max(items.count,1)}override func tableView(_ t:UITableView,cellForRowAt i:IndexPath)->UITableViewCell{let c=UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.backgroundColor=CBXTheme.panel;c.textLabel?.textColor=CBXTheme.cream;c.detailTextLabel?.textColor=.systemGray2;if items.isEmpty{c.textLabel?.text="Quiet in here";c.detailTextLabel?.text="Your CornBox activity will show up here."}else{c.textLabel?.text=items[i.row].title;c.detailTextLabel?.text=items[i.row].detail;c.imageView?.image=UIImage(systemName:"sparkles");c.imageView?.tintColor=CBXTheme.peach}return c} }
