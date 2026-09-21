import SwiftUI
import UIKit

struct RootViewV8: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let tabs = V7Tabs(store: .shared)
        tabs.loadViewIfNeeded()
        let home = V8Home(feed: tabs.feed)
        let nav = UINavigationController(rootViewController: home)
        nav.setNavigationBarHidden(true, animated: false)
        nav.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house.fill"), tag: 0)
        var vcs = tabs.viewControllers ?? []
        if !vcs.isEmpty { vcs[0] = nav; tabs.viewControllers = vcs }
        return tabs
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

final class V8SocialState {
    static let shared = V8SocialState()
    private let d = UserDefaults.standard
    var likes: Set<String> { get { Set(d.stringArray(forKey: "v8.likes") ?? []) } set { d.set(Array(newValue), forKey: "v8.likes") } }
    var comments: [String:[String]] { get { (try? JSONDecoder().decode([String:[String]].self, from: d.data(forKey: "v8.comments") ?? Data())) ?? [:] } set { d.set(try? JSONEncoder().encode(newValue), forKey: "v8.comments") } }
    var mute: Bool { get { d.bool(forKey: "v8.mute") } set { d.set(newValue, forKey: "v8.mute") } }
    var autoplay: Bool { get { d.object(forKey: "v8.autoplay") == nil ? true : d.bool(forKey: "v8.autoplay") } set { d.set(newValue, forKey: "v8.autoplay") } }
    var bulkAssign: Bool { get { d.object(forKey: "v8.bulk") == nil ? true : d.bool(forKey: "v8.bulk") } set { d.set(newValue, forKey: "v8.bulk") } }
    var haptics: Bool { get { d.object(forKey: "v8.haptics") == nil ? true : d.bool(forKey: "v8.haptics") } set { d.set(newValue, forKey: "v8.haptics") } }
}

final class V8Home: UIViewController {
    let feed: V7Feed
    private let like = V8Action(icon: "heart.fill", label: "Like")
    private let comment = V8Action(icon: "bubble.right.fill", label: "Comment")
    private let share = V8Action(icon: "arrowshape.turn.up.right.fill", label: "Share")
    private let more = V8Action(icon: "ellipsis", label: "More")
    private var timer: Timer?
    init(feed: V7Feed) { self.feed = feed; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder){ fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        addChild(feed); feed.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(feed.view); feed.didMove(toParent:self)
        NSLayoutConstraint.activate([feed.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),feed.view.trailingAnchor.constraint(equalTo:view.trailingAnchor),feed.view.topAnchor.constraint(equalTo:view.topAnchor),feed.view.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        let stack = UIStackView(arrangedSubviews:[like,comment,share,more]); stack.axis = .vertical; stack.spacing = 14; stack.alignment = .center; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-10),stack.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-72),stack.widthAnchor.constraint(equalToConstant:64)])
        like.addTarget(self, action:#selector(toggleLike), for:.touchUpInside); comment.addTarget(self, action:#selector(openComments), for:.touchUpInside); share.addTarget(self, action:#selector(doShare), for:.touchUpInside); more.addTarget(self, action:#selector(openMore), for:.touchUpInside)
        let gear = UIButton(type:.system); gear.setImage(UIImage(systemName:"gearshape.fill"),for:.normal); gear.tintColor=V7Style.cream; gear.backgroundColor=UIColor.black.withAlphaComponent(0.72); gear.layer.cornerRadius=20; gear.translatesAutoresizingMaskIntoConstraints=false; gear.addTarget(self,action:#selector(openSettings),for:.touchUpInside); view.addSubview(gear)
        NSLayoutConstraint.activate([gear.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-13),gear.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:6),gear.widthAnchor.constraint(equalToConstant:40),gear.heightAnchor.constraint(equalToConstant:40)])
        timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self]_ in self?.refresh()}; refresh()
    }
    deinit { timer?.invalidate() }
    private func current() -> V6Media? {
        let c=feed.collection; guard !feed.items.isEmpty else{return nil}; let p=CGPoint(x:c.bounds.midX,y:c.contentOffset.y+c.bounds.midY)
        if let i=c.indexPathForItem(at:p),i.item<feed.items.count{return feed.items[i.item]}
        let n=max(0,min(feed.items.count-1,Int(round(c.contentOffset.y/max(1,c.bounds.height))))); return feed.items[n]
    }
    private func refresh(){ guard let m=current() else{return}; let liked=V8SocialState.shared.likes.contains(m.id); like.setState(active:liked,count:nil); let n=V8SocialState.shared.comments[m.id]?.count ?? 0; comment.setState(active:false,count:n>0 ? "\(n)":nil) }
    @objc private func toggleLike(){ guard let m=current() else{return}; var s=V8SocialState.shared.likes; if s.contains(m.id){s.remove(m.id)}else{s.insert(m.id);if V8SocialState.shared.haptics{UIImpactFeedbackGenerator(style:.medium).impactOccurred()}};V8SocialState.shared.likes=s;refresh() }
    @objc private func openComments(){ guard let m=current() else{return}; let a=UIAlertController(title:"Comments",message:(V8SocialState.shared.comments[m.id] ?? []).isEmpty ? "No comments yet." : V8SocialState.shared.comments[m.id]!.joined(separator:"\n\n"),preferredStyle:.alert);a.addTextField{$0.placeholder="Add a comment…"};a.addAction(UIAlertAction(title:"Post",style:.default){[weak self,weak a]_ in guard let text=a?.textFields?.first?.text?.trimmingCharacters(in:.whitespacesAndNewlines),!text.isEmpty else{return};var all=V8SocialState.shared.comments;all[m.id,default:[]].append(text);V8SocialState.shared.comments=all;self?.refresh()});a.addAction(UIAlertAction(title:"Close",style:.cancel));present(a,animated:true) }
    @objc private func doShare(){ guard let m=current() else{return}; present(UIActivityViewController(activityItems:[m.url],applicationActivities:nil),animated:true) }
    @objc private func openMore(){ guard let m=current() else{return}; let a=UIAlertController(title:"Media options",message:m.id,preferredStyle:.actionSheet);a.addAction(UIAlertAction(title:"Like / Unlike",style:.default){[weak self]_ in self?.toggleLike()});a.addAction(UIAlertAction(title:"Share",style:.default){[weak self]_ in self?.doShare()});a.addAction(UIAlertAction(title:"Open creator",style:.default){[weak self]_ in guard let self,let cr=self.feed.store.creator(m) else{return};self.navigationController?.pushViewController(V7Profile(store:self.feed.store,creator:cr),animated:true)});a.addAction(UIAlertAction(title:"Remove media",style:.destructive){[weak self]_ in try? FileManager.default.removeItem(at:m.url);self?.feed.store.scan();self?.feed.store.changed?()});a.addAction(UIAlertAction(title:"Cancel",style:.cancel));present(a,animated:true) }
    @objc private func openSettings(){ navigationController?.pushViewController(V8SettingsController(),animated:true) }
}

final class V8Action: UIControl {
    private let icon=UIImageView(); private let text=UILabel(); private let count=UILabel()
    init(icon:String,label:String){super.init(frame:.zero);self.icon.image=UIImage(systemName:icon);self.icon.tintColor=.white;self.icon.contentMode=.scaleAspectFit;text.text=label;text.textColor=.white;text.font=.systemFont(ofSize:10,weight:.bold);count.textColor=.white;count.font=.systemFont(ofSize:10,weight:.bold);let s=UIStackView(arrangedSubviews:[self.icon,text,count]);s.axis=.vertical;s.spacing=2;s.alignment=.center;s.isUserInteractionEnabled=false;s.translatesAutoresizingMaskIntoConstraints=false;addSubview(s);NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo:leadingAnchor),s.trailingAnchor.constraint(equalTo:trailingAnchor),s.topAnchor.constraint(equalTo:topAnchor),s.bottomAnchor.constraint(equalTo:bottomAnchor),self.icon.widthAnchor.constraint(equalToConstant:30),self.icon.heightAnchor.constraint(equalToConstant:30)]);count.isHidden=true;translatesAutoresizingMaskIntoConstraints=false;heightAnchor.constraint(greaterThanOrEqualToConstant:52).isActive=true}
    required init?(coder:NSCoder){fatalError()}
    func setState(active:Bool,count:String?){icon.tintColor=active ? V7Style.peach:.white;self.count.text=count;self.count.isHidden=count==nil}
}

final class V8SettingsController: UITableViewController {
    let p=V8SocialState.shared
    let sections:[[String]]=[["Auto-scroll","Auto-scroll speed","Loop feed"],["Autoplay visible video","Mute videos by default","Pause on tap"],["Bulk assign after import","Haptic feedback"],["CornBox appearance","Storage & media"]]
    override func viewDidLoad(){super.viewDidLoad();title="Settings";view.backgroundColor=V7Style.bg;tableView.backgroundColor=V7Style.bg;navigationController?.navigationBar.tintColor=V7Style.peach;navigationController?.navigationBar.titleTextAttributes=[.foregroundColor:V7Style.cream]}
    override func numberOfSections(in tableView:UITableView)->Int{sections.count}
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int{sections[section].count}
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String?{["FEED","PLAYBACK","IMPORT & FEEL","APP"][section]}
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell{let c=UITableViewCell(style:.value1,reuseIdentifier:nil);c.backgroundColor=V7Style.panel;c.textLabel?.textColor=V7Style.cream;c.detailTextLabel?.textColor=V7Style.mint;let t=sections[indexPath.section][indexPath.row];c.textLabel?.text=t
        if t=="Auto-scroll"{c.accessoryView=sw(V7Settings.shared.autoScroll,#selector(autoChanged(_:)))}
        else if t=="Loop feed"{c.accessoryView=sw(V7Settings.shared.loopVideos,#selector(loopChanged(_:)))}
        else if t=="Autoplay visible video"{c.accessoryView=sw(p.autoplay,#selector(autoplayChanged(_:)))}
        else if t=="Mute videos by default"{c.accessoryView=sw(p.mute,#selector(muteChanged(_:)))}
        else if t=="Bulk assign after import"{c.accessoryView=sw(p.bulkAssign,#selector(bulkChanged(_:)))}
        else if t=="Haptic feedback"{c.accessoryView=sw(p.haptics,#selector(hapticChanged(_:)))}
        else if t=="Pause on tap"{c.detailTextLabel?.text="On"}
        else if t=="Auto-scroll speed"{c.detailTextLabel?.text="\(Int(V7Settings.shared.autoSeconds)) sec";c.accessoryType=.disclosureIndicator}
        else if t=="CornBox appearance"{c.detailTextLabel?.text="Purple · Peach"}
        else {c.detailTextLabel?.text="Local only"};return c}
    private func sw(_ on:Bool,_ action:Selector)->UISwitch{let s=UISwitch();s.isOn=on;s.onTintColor=V7Style.peach;s.addTarget(self,action:action,for:.valueChanged);return s}
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath){tableView.deselectRow(at:indexPath,animated:true);guard sections[indexPath.section][indexPath.row]=="Auto-scroll speed" else{return};let a=UIAlertController(title:"Auto-scroll speed",message:"Choose how long before CornBox advances",preferredStyle:.actionSheet);for n in [3,5,6,8,10,15,20]{a.addAction(UIAlertAction(title:"\(n) seconds",style:.default){_ in V7Settings.shared.autoSeconds=Double(n);self.tableView.reloadData()})};a.addAction(UIAlertAction(title:"Cancel",style:.cancel));present(a,animated:true)}
    @objc func autoChanged(_ s:UISwitch){V7Settings.shared.autoScroll=s.isOn};@objc func loopChanged(_ s:UISwitch){V7Settings.shared.loopVideos=s.isOn};@objc func autoplayChanged(_ s:UISwitch){p.autoplay=s.isOn};@objc func muteChanged(_ s:UISwitch){p.mute=s.isOn};@objc func bulkChanged(_ s:UISwitch){p.bulkAssign=s.isOn};@objc func hapticChanged(_ s:UISwitch){p.haptics=s.isOn}
}
