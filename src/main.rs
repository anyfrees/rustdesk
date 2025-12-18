#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

// ▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼
// 1. 核心引用
// ▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼
use librustdesk::*;
use std::thread;
use std::time::Duration;

// ============================================================================
//  辅助函数：智能初始化逻辑 (Smart Init)
//  功能：只在第一次运行时强制设置【密码】，恢复默认 P2P 模式
// ============================================================================
fn auto_init_settings() {
    thread::spawn(move || {
        // 延时 5 秒，确保配置模块加载完毕
        thread::sleep(Duration::from_secs(5));

        // 1. 获取配置目录
        let home_dir = hbb_common::config::Config::get_home();
        // 定义标记文件路径
        let mark_file = home_dir.join(".config_initialized");

        // 2. 检查标记文件是否存在
        // 如果存在，说明已经初始化过了，尊重用户后续的修改，不再覆盖
        if mark_file.exists() {
            hbb_common::log::info!("【AutoInit】Mark file found. Skipping default setup.");
            return;
        }

        // 3. 如果标记文件不存在 (第一次运行)
        hbb_common::log::info!("【AutoInit】First run detected. Applying default settings...");

        // ---------------------------------------------------------------------
        // 【设置 1】 固定密码 (保留)
        // ---------------------------------------------------------------------
        let default_password = "ck@stu.xidian.edu.cn";
        
        // 方式 A: 底层设置
        let _ = std::thread::spawn(move || {
            hbb_common::config::Config::set_permanent_password(default_password);
        }).join();

        // 方式 B: UI 接口设置 (带 librustdesk:: 前缀)
        let _ = std::panic::catch_unwind(|| {
             librustdesk::ui_interface::set_permanent_password(default_password.to_string());
        });
        hbb_common::log::info!("【AutoInit】Default password set.");

        // ---------------------------------------------------------------------
        // 【已移除】 强制中继模式的代码
        // 现在恢复默认行为：优先尝试 P2P 直连，速度更快
        // ---------------------------------------------------------------------

        // 4. 创建标记文件 (打疫苗)
        if let Ok(mut file) = std::fs::File::create(&mark_file) {
            use std::io::Write;
            let _ = file.write_all(b"done");
            hbb_common::log::info!("【AutoInit】Mark file created. Settings won't be overwritten next time.");
        } else {
            hbb_common::log::error!("【AutoInit】Failed to create mark file!");
        }
    });
}

// ============================================================================
//  入口 1：Android / iOS / Flutter 模式
// ============================================================================
#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter"))]
fn main() {
    if !common::global_init() {
        eprintln!("Global initialization failed.");
        return;
    }

    // 【新增】启动智能设置
    auto_init_settings();

    common::test_rendezvous_server();
    common::test_nat_type();
    
    if let Some(args) = crate::core_main::core_main().as_mut() {
         // Flutter 逻辑
    }

    common::global_clean();
}

// ============================================================================
//  入口 2：Windows / Linux / macOS 桌面版 (Sciter UI)
// ============================================================================
#[cfg(not(any(
    target_os = "android",
    target_os = "ios",
    feature = "cli",
    feature = "flutter"
)))]
fn main() {
    #[cfg(all(windows, not(feature = "inline")))]
    unsafe {
        winapi::um::shellscalingapi::SetProcessDpiAwareness(2);
    }

    // 【新增】启动智能设置
    auto_init_settings();

    if let Some(args) = crate::core_main::core_main().as_mut() {
        ui::start(args);
    }
    common::global_clean();
}

// ============================================================================
//  入口 3：命令行模式 & 后台服务模式 (Service)
// ============================================================================
#[cfg(feature = "cli")]
fn main() {
    if !common::global_init() {
        return;
    }
    use clap::App;
    use hbb_common::log;
    
    let args = format!(
        "-p, --port-forward=[PORT-FORWARD-OPTIONS] 'Format: remote-id:local-port:remote-port[:remote-host]'
        -c, --connect=[REMOTE_ID] 'test only'
        -k, --key=[KEY] ''
        -s, --server=[] 'Start server'",
    );
    let matches = App::new("rustdesk")
        .version(crate::VERSION)
        .author("Purslane Ltd<info@rustdesk.com>")
        .about("RustDesk command line tool")
        .args_from_usage(&args)
        .get_matches();

    use hbb_common::{config::LocalConfig, env_logger::*};
    init_from_env(Env::default().filter_or(DEFAULT_FILTER_ENV, "info"));

    // 处理端口转发
    if let Some(p) = matches.value_of("port-forward") {
        let options: Vec<String> = p.split(":").map(|x| x.to_owned()).collect();
        if options.len() < 3 {
            log::error!("Wrong port-forward options");
            return;
        }
        let mut port = 0;
        if let Ok(v) = options[1].parse::<i32>() {
            port = v;
        } else {
            log::error!("Wrong local-port");
            return;
        }
        let mut remote_port = 0;
        if let Ok(v) = options[2].parse::<i32>() {
            remote_port = v;
        } else {
            log::error!("Wrong remote-port");
            return;
        }
        let mut remote_host = "localhost".to_owned();
        if options.len() > 3 {
            remote_host = options[3].clone();
        }
        common::test_rendezvous_server();
        common::test_nat_type();
        let key = matches.value_of("key").unwrap_or("").to_owned();
        let token = LocalConfig::get_option("access_token");
        cli::start_one_port_forward(
            options[0].clone(),
            port,
            remote_host,
            remote_port,
            key,
            token,
        );
    
    // 处理连接测试
    } else if let Some(p) = matches.value_of("connect") {
        common::test_rendezvous_server();
        common::test_nat_type();
        let key = matches.value_of("key").unwrap_or("").to_owned();
        let token = LocalConfig::get_option("access_token");
        cli::connect_test(p, key, token);

    // ▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼
    // 处理服务端逻辑 (Windows Service 分支)
    // ▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼
    } else if let Some(p) = matches.value_of("server") {
        log::info!("id={}", hbb_common::config::Config::get_id());
        
        // 【新增】后台服务启动时，也执行智能设置
        auto_init_settings();

        crate::start_server(true, false);
    }
    common::global_clean();
}