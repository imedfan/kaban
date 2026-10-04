import SwiftUI
import AppKit
import WebKit
import CryptoKit

@MainActor enum ReferenceExport {
    static func exportAll(to directory:String) async throws {
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        let requested=CommandLine.arguments.firstIndex(of:"--frame-id").flatMap {i in CommandLine.arguments.count>i+1 ? CommandLine.arguments[i+1]:nil}
        let runtimeFrames:[ReferenceFrame]=[.init(id:"runtime/latest-board",source:"runtime-board.html",width:1440,height:900,dark:false,route:"board"),.init(id:"runtime/latest-board-dark",source:"runtime-board-dark.html",width:1440,height:900,dark:true,route:"board")]
        let frames=(ReferenceFrame.all+runtimeFrames).filter{requested==nil || requested==$0.id}
        var records:[[String:String]]=[]
        for frame in frames {
            FileHandle.standardError.write(Data("rendering \(frame.id)\n".utf8))
            let demo=ReferenceDemo()
            if frame.route=="pipeline-invalid" {demo.model=""}
            let url=URL(fileURLWithPath:directory).appendingPathComponent(frame.id+".png")
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}
            if CommandLine.arguments.contains("--native-frames"){try await capture(ReferenceFrameView(demo:demo,frame:frame),width:frame.width,height:frame.height,to:url)}else{try await captureSource(frame,to:url)}
            let pngData=try Data(contentsOf:url)
            let sourceURL=ReferenceSourceWeb.root.appendingPathComponent(frame.source)
            let sourceData=try Data(contentsOf:sourceURL)
            let bitmap=NSBitmapImageRep(data:pngData)
            records.append(["id":frame.id,"source":frame.source,"theme":frame.dark ? "dark":"light","viewport":"\(Int(frame.width))x\(Int(frame.height))","pixels":"\(bitmap?.pixelsWide ?? 0)x\(bitmap?.pixelsHigh ?? 0)","render":url.path,"result":"rendered","sourceSHA256":SHA256.hash(data:sourceData).map{String(format:"%02x",$0)}.joined(),"renderSHA256":SHA256.hash(data:pngData).map{String(format:"%02x",$0)}.joined(),"findings":"Original DOM; WebKit takeSnapshot may omit backdrop-filter blur; system font/emoji vary from reference renderer. Visual review required."])
            print("rendered \(frame.id)")
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(records).write(to:URL(fileURLWithPath:directory).appendingPathComponent("frames.json"))
    }
    static func capture<V:View>(_ view:V,width:CGFloat,height:CGFloat,to url:URL) async throws {
        let host=NSHostingView(rootView:view)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=host
        host.frame=NSRect(x:0,y:0,width:width,height:height)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for:.milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw NSError(domain:"ReferenceExport",code:1)}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw NSError(domain:"ReferenceExport",code:2)}
        try png.write(to:url)
        window.close()
    }
}

@MainActor extension ReferenceExport {
    final class SourceLoad:NSObject,WKNavigationDelegate {
        var continuation:CheckedContinuation<Void,Error>?
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){continuation?.resume();continuation=nil}
        func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error){continuation?.resume(throwing:error);continuation=nil}
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error){continuation?.resume(throwing:error);continuation=nil}
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping @MainActor @Sendable (WKNavigationActionPolicy)->Void){decisionHandler(ReferenceSourceWeb.allowed(navigationAction.request.url) ? .allow:.cancel)}
    }
    static func captureSource(_ frame:ReferenceFrame,to url:URL) async throws {
        let web=WKWebView(frame:.init(x:0,y:0,width:frame.width,height:frame.height),configuration:ReferenceSourceWeb.configuration(interactive:frame.id.hasPrefix("runtime/")))
        try await ReferenceSourceWeb.blockNetwork(web)
        let window=NSWindow(contentRect:web.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=web;window.orderFront(nil)
        let delegate=SourceLoad();web.navigationDelegate=delegate
        defer{web.navigationDelegate=nil;window.close()}
        let source=ReferenceSourceWeb.root.appendingPathComponent(frame.source)
        guard ReferenceSourceWeb.allowed(source) else{throw NSError(domain:"ReferenceSourceExport",code:1)}
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in delegate.continuation=continuation;web.loadFileURL(source,allowingReadAccessTo:ReferenceSourceWeb.root);Task{try? await Task.sleep(for:.seconds(30));if let pending=delegate.continuation{delegate.continuation=nil;pending.resume(throwing:NSError(domain:"ReferenceSourceExportTimeout",code:30))}}}
        try await ReferenceSourceWeb.execute(web,"await document.fonts.ready; return true")
        if frame.id.hasPrefix("runtime/"){let demo=ReferenceDemo();demo.dark=frame.dark;try await ReferenceSourceWeb.execute(web,"await window.kabanProject(state); return true",arguments:["state":demo.domProjection])}
        try await Task.sleep(for:.milliseconds(250))
        let config=WKSnapshotConfiguration();config.rect=web.bounds;config.snapshotWidth=NSNumber(value:frame.width)
        let image=try await web.takeSnapshot(configuration:config)
        guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else{throw NSError(domain:"ReferenceSourceExport",code:2)}
        try png.write(to:url);web.navigationDelegate=nil;window.close()
    }
}

@MainActor enum ReferenceSourceSmoke {
    static func run() async throws->[String] {
        var checks=try await ReferenceDemo.smoke()
        func require(_ condition:Bool,_ name:String)throws{guard condition else{throw NSError(domain:"ReferenceDOMSmoke",code:1,userInfo:[NSLocalizedDescriptionKey:name])};checks.append(name)}
        let demo=ReferenceDemo(),coordinator=ReferenceSourceWebView.Coordinator(demo:ReferenceDemo())
        coordinator.demo=demo
        let config=ReferenceSourceWeb.configuration(interactive:true);config.userContentController.add(coordinator,name:"kabanDemo")
        let web=WKWebView(frame:.init(x:0,y:0,width:1440,height:900),configuration:config);coordinator.web=web
        try await ReferenceSourceWeb.blockNetwork(web)
        let window=NSWindow(contentRect:web.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=web;window.orderFront(nil)
        let loader=ReferenceExport.SourceLoad();web.navigationDelegate=loader
        defer{web.configuration.userContentController.removeScriptMessageHandler(forName:"kabanDemo");web.navigationDelegate=nil;window.close()}
        func load(_ source:String) async throws {try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in loader.continuation=continuation;web.loadFileURL(ReferenceSourceWeb.root.appendingPathComponent(source),allowingReadAccessTo:ReferenceSourceWeb.root);Task{try? await Task.sleep(for:.seconds(30));if let pending=loader.continuation{loader.continuation=nil;pending.resume(throwing:NSError(domain:"ReferenceSmokeTimeout",code:30))}}};coordinator.ready=true}
        func script(_ code:String) async throws->Any {
            let encoded:String=try await withCheckedThrowingContinuation { continuation in
                web.callAsyncJavaScript("return JSON.stringify(await (async()=>{"+code+"})());",arguments:[:],in:nil,in:.page,completionHandler:{result in
                    switch result {case .success(let value):continuation.resume(returning:value as? String ?? "null");case .failure(let error):continuation.resume(throwing:error)}
                })
            }
            return try JSONSerialization.jsonObject(with:Data(encoded.utf8),options:.fragmentsAllowed)
        }
        func sync() async throws{coordinator.projection=demo.domProjection;try await ReferenceSourceWeb.execute(web,"await window.kabanProject(state); return true",arguments:["state":demo.domProjection]);try await Task.sleep(for:.milliseconds(100))}
        try await load("runtime-board.html")
        _ = try await script("[...document.querySelectorAll('.proj')].find(e=>e.querySelector('.pn')?.textContent==='kaban').click(); return true")
        try await Task.sleep(for:.milliseconds(50));try require(demo.selectedProject=="kaban","DOM project click → selected project")
        _ = try await script("[...document.querySelectorAll('.tbtn')].find(e=>e.textContent.trim()==='Задача').click(); return true")
        try await Task.sleep(for:.milliseconds(50));try require(demo.sheet=="create","DOM create button → native editor state")
        demo.draftTitle="DOM Smoke Task";demo.draftBody="exact Markdown\n";demo.saveTask();let id=demo.selected!;try await sync()
        let created=try await script("return [...document.querySelectorAll('.card-title')].some(e=>e.textContent==='DOM Smoke Task')") as? Bool ?? false
        if !created {let diagnostic=try await script("return JSON.stringify({type:typeof window.kabanProject,lanes:[...document.querySelectorAll('.lane')].map(l=>({name:l.querySelector('.ln')?.textContent,columns:[...l.querySelectorAll('.col-h b')].map(e=>e.textContent)})),cards:[...document.querySelectorAll('.tid')].map(e=>e.textContent)})");FileHandle.standardError.write(Data("DOM diagnostic: \(diagnostic) native: \(String(describing:demo.tasks.last))\n".utf8))}
        try require(created,"native save → Swift state → original DOM card")
        _ = try await script("[...document.querySelectorAll('.card')].find(e=>e.querySelector('.tid')?.textContent.startsWith('DEMO-')).dispatchEvent(new MouseEvent('contextmenu',{bubbles:true})); return true")
        try await Task.sleep(for:.milliseconds(50));try require(demo.sheet=="move","DOM context menu → native move sheet")
        demo.returnTarget="Dev";demo.moveSelected();try await sync()
        let moved=try await script("return [...document.querySelectorAll('.lane')].find(e=>e.querySelector('.ln')?.textContent==='kaban').querySelectorAll('.col')[1].textContent.includes('DOM Smoke Task')") as? Bool ?? false
        try require(moved,"move command → queue projection in target DOM column")
        demo.action("Отменить",taskID:id);try await sync()
        let cancelled=try await script("return [...document.querySelectorAll('.card')].some(e=>e.querySelector('.tid')?.textContent.startsWith('DEMO-')&&e.classList.contains('st-cancelled'))") as? Bool ?? false
        try require(cancelled,"cancel → DOM cancelled card")
        try await load("v0.2.1/details-suspicious.html");demo.selected="SHOP-52"
        _ = try await script("[...document.querySelectorAll('.panel .btn')].find(e=>e.textContent.includes('Принять файлы')).click(); return true")
        try await Task.sleep(for:.milliseconds(50));try require(demo.pending.contains("files:SHOP-52"),"DOM accept click → correlated pending")
        try await Task.sleep(for:.milliseconds(700));try await sync();try require(demo.acceptedTaskIDs.contains("SHOP-52"),"DOM accept click → task acceptance")
        let cleared=try await script("return document.querySelectorAll('.panel .sft .r').length===0") as? Bool ?? false
        try require(cleared,"accepted Swift state → DOM suspicious set removed")
        try await load("runtime-board.html");try await sync()
        let afterReload=try await script("return [...document.querySelectorAll('.lane')].find(e=>e.querySelector('.ln')?.textContent==='shop-api').querySelectorAll('.col')[2].textContent.includes('SHOP-52')") as? Bool ?? false
        try require(afterReload,"reload reapplies mutations from Swift memory state")
        // Original add-project modal DOM, identity validation, and repeated lane projection.
        _ = try await script("document.querySelector('.sb-sec svg').dispatchEvent(new MouseEvent('click',{bubbles:true})); return true")
        try await Task.sleep(for:.milliseconds(50));try await sync()
        try require(demo.webModal=="add","DOM project plus → original modal")
        _ = try await script("document.querySelector('.kaban-modal-host .primary').click(); return true")
        try await Task.sleep(for:.milliseconds(50));try await sync()
        try require(demo.identityMode==1,"original add-project submit → missing identity state")
        _ = try await script("const fields=[...document.querySelectorAll('.kaban-modal-host .f2')];for(const [label,value]of [['Папка','/tmp/smoke-project'],['Имя','Smoke Author'],['Почта','smoke@example.com']]){const input=fields.find(e=>e.firstElementChild.textContent.trim()===label)?.querySelector('.inp');if(!input)throw Error('field '+label+' available:'+fields.map(e=>e.firstElementChild.textContent.trim()).join('|'));input.textContent=value;input.dispatchEvent(new Event('input',{bubbles:true}));} return true")
        try await Task.sleep(for:.milliseconds(50))
        _ = try await script("document.querySelector('.kaban-modal-host .primary').click(); return true")
        try await Task.sleep(for:.milliseconds(50));demo.notice=nil;try await sync()
        try require(demo.projects.contains("smoke-project") && demo.identities["smoke-project"]?.1=="smoke@example.com","DOM identity inputs → added memory project")
        _ = try await script("[...document.querySelectorAll('.proj')].find(e=>e.querySelector('.pn')?.textContent==='smoke-project').click(); return true")
        try await Task.sleep(for:.milliseconds(50));demo.sheet="create";demo.draftTitle="New Project Task";demo.saveTask();try await sync();try await sync()
        try await load("runtime-board.html");try await sync()
        let projectTask=try await script("return [...document.querySelectorAll('.lane')].find(e=>e.querySelector('.ln')?.textContent==='smoke-project').querySelector('.col').textContent.includes('New Project Task')") as? Bool ?? false
        try require(projectTask,"new project lane + created task survive projection and reload")
        // Original return form sends typed text, including literal HTML, to the selected task only.
        demo.selected="SHOP-52";demo.webModal="return-gate";demo.returnNote="";try await sync()
        _ = try await script("const note=document.querySelector('.kaban-modal-host .ta');note.focus();note.textContent='<img onerror=bad()> keep files';note.dispatchEvent(new Event('input',{bubbles:true})); return true")
        try await Task.sleep(for:.milliseconds(50));try await sync()
        _ = try await script("const note=document.querySelector('.kaban-modal-host .ta');note.textContent+=' second';note.dispatchEvent(new Event('input',{bubbles:true})); return true")
        try await Task.sleep(for:.milliseconds(50));try await sync()
        let focused=try await script("return document.activeElement===document.querySelector('.kaban-modal-host .ta')") as? Bool ?? false
        try require(focused,"sequential return typing preserves active editable field")
        let escaped=try await script("return !document.querySelector('.kaban-modal-host .ta img')") as? Bool ?? false
        try require(escaped && demo.returnNote.contains("<img"),"return note is literal text, no HTML injection")
        _ = try await script("document.querySelector('.kaban-modal-host .primary').click(); return true")
        try await Task.sleep(for:.milliseconds(50));demo.notice=nil
        try require(demo.tasks.first(where:{$0.id=="SHOP-52"})?.stage==demo.returnTarget,"original return submit mutates selected task")
        demo.selected="SHOP-29";demo.webModal="return-merge";demo.returnNote="";try await sync()
        _ = try await script("document.querySelector('.kaban-modal-host .primary').click(); return true")
        try await Task.sleep(for:.milliseconds(50));demo.notice=nil
        try require(demo.tasks.first(where:{$0.id=="SHOP-29"})?.files.isEmpty==true,"empty original merge return accepts selected file set")
        // Settings are changed by source radio controls, then restored through apply/cancel and reload.
        try await load("v0.2.1/project-git.html");try await sync()
        _ = try await script("document.querySelectorAll('.preset')[0].click(); return true")
        try await Task.sleep(for:.milliseconds(50));let saved=demo.preset
        _ = try await script("[...document.querySelectorAll('.btn,.tbtn')].find(e=>/Сохранить|Применить/.test(e.textContent)).click(); return true")
        try await Task.sleep(for:.milliseconds(50));demo.notice=nil
        _ = try await script("document.querySelectorAll('.preset')[1].click(); return true")
        try await Task.sleep(for:.milliseconds(50))
        _ = try await script("[...document.querySelectorAll('.btn,.tbtn')].find(e=>e.textContent.trim()==='Отменить').click(); return true")
        try await Task.sleep(for:.milliseconds(50));try await load("v0.2.1/project-git.html");try await sync()
        let restored=try await script("return document.querySelector('.preset.on b').textContent") as? String ?? ""
        try require(demo.preset==saved && restored.contains(saved),"DOM settings apply/cancel/reload restores selected preset")
        // SwiftUI observation, without manual coordinator projection.
        let observed=ReferenceDemo();let host=NSHostingView(rootView:ReferenceRuntime(demo:observed));let hosted=NSWindow(contentRect:.init(x:0,y:0,width:1440,height:900),styleMask:[.borderless],backing:.buffered,defer:false);hosted.isReleasedWhenClosed=false;hosted.contentView=host;host.frame=hosted.contentLayoutRect;hosted.orderFront(nil)
        defer{hosted.close()}
        func findWeb(_ view:NSView)->WKWebView?{if let web=view as? WKWebView{return web};return view.subviews.lazy.compactMap{findWeb($0)}.first}
        var observedWeb:WKWebView?
        for _ in 0..<100{host.layoutSubtreeIfNeeded();observedWeb=findWeb(host);if observedWeb?.isLoading==false && observedWeb?.url != nil{break};try await Task.sleep(for:.milliseconds(50))}
        guard let observedWeb else{throw NSError(domain:"ReferenceObservationSmoke",code:1)}
        try await Task.sleep(for:.milliseconds(200));observed.tasks[0].title="Observed SwiftUI Title"
        try await Task.sleep(for:.milliseconds(300))
        let observedTitle:String=try await withCheckedThrowingContinuation{continuation in observedWeb.callAsyncJavaScript("return [...document.querySelectorAll('.card-title')].find(e=>e.textContent==='Observed SwiftUI Title')?.textContent || ''",arguments:[:],in:nil,in:.page,completionHandler:{result in switch result{case .success(let value):continuation.resume(returning:value as? String ?? "");case .failure(let error):continuation.resume(throwing:error)}})}
        try require(observedTitle=="Observed SwiftUI Title","runtime NSHostingView observation updates original DOM automatically")
        try require(!ReferenceSourceWeb.allowed(URL(string:"https://example.com")) && !ReferenceSourceWeb.allowed(URL(fileURLWithPath:"/tmp/outside.html")),"navigation allowlist rejects remote/outside bundle")
        try require(ReferenceDemoAction(rawValue:"exec")==nil,"unknown bridge command rejected")
        web.configuration.userContentController.removeScriptMessageHandler(forName:"kabanDemo");web.navigationDelegate=nil;window.close()
        return checks
    }
}
