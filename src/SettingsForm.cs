// SettingsForm.cs  - 配置界面（基本设置 + 后台应用管理）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;

public class SettingsForm : Form
{
    public AppConfig Result { get; private set; }

    AppConfig cfg;
    TabControl tabs;
    TextBox txtPath, txtGame, txtMask;
    ComboBox cmbAffinity, cmbPriority;
    NumericUpDown numCores, numInterval, numLog;
    CheckBox chkAuto, chkClearLog;
    DataGridView grid;
    Label lblMemSummary;
    Button btnSave, btnCancel, btnDetect, btnBrowse, btnRefresh;
    readonly HashSet<string> preChecked = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    public SettingsForm(AppConfig config)
    {
        cfg = config ?? new AppConfig();
        if (cfg.GameKillApps != null)
            foreach (string n in cfg.GameKillApps) preChecked.Add(n);
        BuildUi();
        RefreshProcessList();
    }

    void BuildUi()
    {
        Text = "配置 - cs2wd-40";
        Size = new Size(760, 660);
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        BackColor = Color.FromArgb(246, 247, 250);
        Font = new Font("Microsoft YaHei UI", 9);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        Label hint = new Label();
        hint.Text = "系统：" + Environment.OSVersion.VersionString + "   ·   逻辑核心 " + Environment.ProcessorCount +
                    "   ·   " + (Environment.OSVersion.Version.Build >= 19041 ? "支持效率模式" : "不支持效率模式（Win10 2004 以下）");
        hint.Location = new Point(14, 10);
        hint.Size = new Size(720, 20);
        hint.ForeColor = Color.Gray;
        Controls.Add(hint);

        tabs = new TabControl();
        tabs.Location = new Point(12, 36);
        tabs.Size = new Size(724, 520);
        Controls.Add(tabs);

        TabPage page1 = new TabPage("① 基本设置");
        page1.BackColor = Color.White;
        tabs.TabPages.Add(page1);
        BuildPage1(page1);

        TabPage page2 = new TabPage("② 后台应用管理");
        page2.BackColor = Color.White;
        tabs.TabPages.Add(page2);
        BuildPage2(page2);

        btnSave = MakeBtn("保存并应用", new Point(520, 570), new Size(112, 34), Color.FromArgb(46, 160, 90), Color.White, true);
        btnCancel = MakeBtn("取消", new Point(640, 570), new Size(96, 34), Color.FromArgb(240, 243, 248), Color.FromArgb(60, 70, 90), false);
        Controls.Add(btnSave);
        Controls.Add(btnCancel);

        btnSave.Click += delegate { SaveAndClose(); };
        btnCancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };
    }

    Button MakeBtn(string text, Point loc, Size size, Color back, Color fore, bool bold)
    {
        Button b = new Button();
        b.Text = text;
        b.Location = loc;
        b.Size = size;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderColor = back == Color.White ? Color.Silver : back;
        b.BackColor = back;
        b.ForeColor = fore;
        if (bold) b.Font = new Font("Microsoft YaHei UI", 9, FontStyle.Bold);
        b.Cursor = Cursors.Hand;
        return b;
    }

    // ------------------------------------------------------------
    //  页 1：基本设置
    // ------------------------------------------------------------
    void BuildPage1(TabPage page)
    {
        int y = 16;

        Label l1 = Field(page, "平台 exe 路径", y);
        txtPath = new TextBox();
        txtPath.Location = new Point(130, y - 3);
        txtPath.Size = new Size(420, 24);
        txtPath.Text = cfg.PlatformPath;
        page.Controls.Add(txtPath);

        btnBrowse = MakeBtn("浏览", new Point(558, y - 5), new Size(62, 28), Color.FromArgb(240, 243, 248), Color.FromArgb(60, 70, 90), false);
        page.Controls.Add(btnBrowse);
        btnBrowse.Click += delegate
        {
            OpenFileDialog d = new OpenFileDialog();
            d.Filter = "可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*";
            d.Title = "选择完美世界竞技平台的 exe";
            if (d.ShowDialog(this) == DialogResult.OK) txtPath.Text = d.FileName;
        };

        btnDetect = MakeBtn("自动探测", new Point(628, y - 5), new Size(80, 28), Color.FromArgb(230, 238, 250), Color.FromArgb(40, 80, 150), false);
        page.Controls.Add(btnDetect);
        btnDetect.Click += delegate
        {
            string found = MainForm.ResolvePlatformPath("");
            if (!string.IsNullOrEmpty(found) && File.Exists(found))
            {
                txtPath.Text = found;
                MessageBox.Show(this, "已找到：\n" + found, "探测成功", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else MessageBox.Show(this, "未能自动探测到平台路径，请手动点击「浏览」选择。", "未找到", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        };

        y += 44;
        Field(page, "游戏进程名", y);
        txtGame = new TextBox();
        txtGame.Location = new Point(130, y - 3);
        txtGame.Size = new Size(120, 24);
        txtGame.Text = cfg.GameProcessName;
        page.Controls.Add(txtGame);
        Label g2 = new Label();
        g2.Text = "（不带 .exe，如 cs2、dota2、valorant）";
        g2.Location = new Point(258, y);
        g2.Size = new Size(300, 20);
        g2.ForeColor = Color.Gray;
        page.Controls.Add(g2);

        Label chk1 = new Label();
        chk1.Text = "启动时自动打开平台";
        chk1.Location = new Point(560, y - 2);
        chk1.Size = new Size(140, 20);
        page.Controls.Add(chk1);
        chkAuto = new CheckBox();
        chkAuto.Location = new Point(700, y - 3);
        chkAuto.Size = new Size(20, 20);
        chkAuto.Checked = cfg.AutoLaunchPlatform;
        page.Controls.Add(chkAuto);

        y += 44;
        Field(page, "CPU 相关性", y);
        cmbAffinity = new ComboBox();
        cmbAffinity.DropDownStyle = ComboBoxStyle.DropDownList;
        cmbAffinity.Location = new Point(130, y - 3);
        cmbAffinity.Size = new Size(250, 24);
        cmbAffinity.Items.Add("排除 CPU0/1（推荐，平台占用前两核）");
        cmbAffinity.Items.Add("使用全部核心");
        cmbAffinity.Items.Add("自定义掩码");
        switch (cfg.Cs2Affinity)
        {
            case "All": cmbAffinity.SelectedIndex = 1; break;
            case "Custom": cmbAffinity.SelectedIndex = 2; break;
            default: cmbAffinity.SelectedIndex = 0; break;
        }
        page.Controls.Add(cmbAffinity);

        Label ml = new Label();
        ml.Text = "掩码(16进制)：";
        ml.Location = new Point(392, y);
        ml.Size = new Size(92, 20);
        page.Controls.Add(ml);
        txtMask = new TextBox();
        txtMask.Location = new Point(488, y - 3);
        txtMask.Size = new Size(120, 24);
        txtMask.Text = cfg.CustomMask;
        txtMask.Enabled = (cfg.Cs2Affinity == "Custom");
        page.Controls.Add(txtMask);
        cmbAffinity.SelectedIndexChanged += delegate { txtMask.Enabled = cmbAffinity.SelectedIndex == 2; };

        y += 44;
        Field(page, "游戏优先级", y);
        cmbPriority = new ComboBox();
        cmbPriority.DropDownStyle = ComboBoxStyle.DropDownList;
        cmbPriority.Location = new Point(130, y - 3);
        cmbPriority.Size = new Size(250, 24);
        cmbPriority.Items.Add("AboveNormal（高于正常，推荐）");
        cmbPriority.Items.Add("High（高，可能饿死驱动）");
        cmbPriority.Items.Add("Normal（正常）");
        switch (cfg.Cs2Priority)
        {
            case "High": cmbPriority.SelectedIndex = 1; break;
            case "Normal": cmbPriority.SelectedIndex = 2; break;
            default: cmbPriority.SelectedIndex = 0; break;
        }
        page.Controls.Add(cmbPriority);

        y += 46;
        Field(page, "平台占用核数", y);
        numCores = new NumericUpDown();
        numCores.Location = new Point(130, y - 3);
        numCores.Size = new Size(70, 24);
        numCores.Minimum = 1;
        numCores.Maximum = 8;
        numCores.Value = Math.Min(Math.Max(cfg.PlatCoresCount, 1), 8);
        page.Controls.Add(numCores);
        Label c1 = new Label();
        c1.Text = "核（游戏使用剩余核心）";
        c1.Location = new Point(206, y);
        c1.Size = new Size(180, 20);
        c1.ForeColor = Color.Gray;
        page.Controls.Add(c1);

        Label c2 = new Label();
        c2.Text = "巡检间隔";
        c2.Location = new Point(400, y);
        c2.Size = new Size(64, 20);
        page.Controls.Add(c2);
        numInterval = new NumericUpDown();
        numInterval.Location = new Point(468, y - 3);
        numInterval.Size = new Size(90, 24);
        numInterval.Minimum = 500;
        numInterval.Maximum = 10000;
        numInterval.Increment = 500;
        numInterval.Value = Math.Min(Math.Max(cfg.IntervalMs, 500), 10000);
        page.Controls.Add(numInterval);
        Label c3 = new Label();
        c3.Text = "ms";
        c3.Location = new Point(562, y);
        c3.Size = new Size(30, 20);
        c3.ForeColor = Color.Gray;
        page.Controls.Add(c3);

        y += 46;
        Field(page, "日志上限", y);
        numLog = new NumericUpDown();
        numLog.Location = new Point(130, y - 3);
        numLog.Size = new Size(70, 24);
        numLog.Minimum = 1;
        numLog.Maximum = 200;
        numLog.Value = Math.Min(Math.Max(cfg.LogMaxMb, 1), 200);
        page.Controls.Add(numLog);
        Label d1 = new Label();
        d1.Text = "MB（超出自动归档为 .bak）";
        d1.Location = new Point(206, y);
        d1.Size = new Size(200, 20);
        d1.ForeColor = Color.Gray;
        page.Controls.Add(d1);

        chkClearLog = new CheckBox();
        chkClearLog.Text = "游戏结束后自动清理日志";
        chkClearLog.Location = new Point(420, y - 3);
        chkClearLog.Size = new Size(220, 22);
        chkClearLog.Checked = cfg.ClearLogAfterGame;
        page.Controls.Add(chkClearLog);

        Label note = new Label();
        note.Text = "提示：游戏结束后，程序会通读日志并弹窗报告本局错误；若无异常则自动删除日志。";
        note.Location = new Point(16, 392);
        note.Size = new Size(660, 34);
        note.ForeColor = Color.FromArgb(150, 90, 0);
        note.Font = new Font("Microsoft YaHei UI", 8.5f);
        page.Controls.Add(note);
    }

    Label Field(TabPage page, string text, int y)
    {
        Label l = new Label();
        l.Text = text;
        l.Location = new Point(16, y);
        l.Size = new Size(110, 20);
        l.TextAlign = ContentAlignment.MiddleLeft;
        page.Controls.Add(l);
        return l;
    }

    // ------------------------------------------------------------
    //  页 2：后台应用管理
    // ------------------------------------------------------------
    void BuildPage2(TabPage page)
    {
        Label title = new Label();
        title.Text = "勾选的应用会在「游戏启动」时自动关闭。系统关键进程即使勾选也会被脚本保护性忽略。";
        title.Location = new Point(14, 12);
        title.Size = new Size(690, 20);
        title.Font = new Font("Microsoft YaHei UI", 9, FontStyle.Bold);
        page.Controls.Add(title);

        Label legend = new Label();
        legend.Text = "影响等级：  ● 安全 = 关闭无影响      ● 慎用 = 有副作用（可能丢失未保存内容/功能受限）      ● 禁止 = 系统或游戏依赖，不建议关闭";
        legend.Location = new Point(14, 36);
        legend.Size = new Size(690, 20);
        legend.ForeColor = Color.Gray;
        legend.Font = new Font("Microsoft YaHei UI", 8.5f);
        page.Controls.Add(legend);

        grid = new DataGridView();
        grid.Location = new Point(14, 62);
        grid.Size = new Size(676, 380);
        grid.AllowUserToAddRows = false;
        grid.AllowUserToDeleteRows = false;
        grid.AllowUserToResizeRows = false;
        grid.RowHeadersVisible = false;
        grid.BackgroundColor = Color.White;
        grid.BorderStyle = BorderStyle.FixedSingle;
        grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
        grid.MultiSelect = false;
        grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.None;
        grid.Font = new Font("Microsoft YaHei UI", 9);
        page.Controls.Add(grid);

        DataGridViewCheckBoxColumn cCheck = new DataGridViewCheckBoxColumn();
        cCheck.HeaderText = "关闭";
        cCheck.Name = "colCheck";
        cCheck.Width = 46;
        cCheck.SortMode = DataGridViewColumnSortMode.NotSortable;
        grid.Columns.Add(cCheck);

        DataGridViewTextBoxColumn cName = new DataGridViewTextBoxColumn();
        cName.HeaderText = "进程名";
        cName.Name = "colName";
        cName.Width = 150;
        cName.ReadOnly = true;
        grid.Columns.Add(cName);

        DataGridViewTextBoxColumn cMem = new DataGridViewTextBoxColumn();
        cMem.HeaderText = "内存";
        cMem.Name = "colMem";
        cMem.Width = 70;
        cMem.ReadOnly = true;
        cMem.SortMode = DataGridViewColumnSortMode.NotSortable;
        grid.Columns.Add(cMem);

        DataGridViewTextBoxColumn cLv = new DataGridViewTextBoxColumn();
        cLv.HeaderText = "影响";
        cLv.Name = "colLv";
        cLv.Width = 56;
        cLv.ReadOnly = true;
        grid.Columns.Add(cLv);

        DataGridViewTextBoxColumn cDesc = new DataGridViewTextBoxColumn();
        cDesc.HeaderText = "说明";
        cDesc.Name = "colDesc";
        cDesc.AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill;
        cDesc.ReadOnly = true;
        grid.Columns.Add(cDesc);

        btnRefresh = MakeBtn("🔄 刷新进程列表", new Point(14, 452), new Size(160, 30), Color.FromArgb(230, 238, 250), Color.FromArgb(40, 80, 150), false);
        page.Controls.Add(btnRefresh);
        btnRefresh.Click += delegate { RefreshProcessList(); };

        lblMemSummary = new Label();
        lblMemSummary.Location = new Point(186, 456);
        lblMemSummary.Size = new Size(500, 22);
        lblMemSummary.ForeColor = Color.Gray;
        lblMemSummary.Font = new Font("Microsoft YaHei UI", 8.5f);
        page.Controls.Add(lblMemSummary);

        grid.CellValueChanged += OnCellValueChanged;
        grid.CellFormatting += delegate (object s, DataGridViewCellFormattingEventArgs e)
        {
            if (e.RowIndex < 0) return;
            DataGridViewRow row = grid.Rows[e.RowIndex];
            string name = Convert.ToString(row.Cells["colName"].Value);
            Impact im = ImpactDb.Get(name);
            if (grid.Columns[e.ColumnIndex].Name == "colLv")
            {
                e.CellStyle.ForeColor = ImpactDb.LevelColor(im.Level);
                e.CellStyle.Font = new Font("Microsoft YaHei UI", 9, FontStyle.Bold);
            }
            if (grid.Columns[e.ColumnIndex].Name == "colDesc")
            {
                e.CellStyle.ForeColor = im.Level == ImpactLevel.Danger ? Color.FromArgb(150, 40, 40) : Color.FromArgb(70, 76, 90);
            }
        };
    }

    void RefreshProcessList()
    {
        Cursor = Cursors.WaitCursor;
        List<KeyValuePair<string, ulong>> list = new List<KeyValuePair<string, ulong>>();
        Dictionary<string, ulong> agg = new Dictionary<string, ulong>();
        try
        {
            foreach (Process p in Process.GetProcesses())
            {
                string nm = "";
                ulong mb = 0;
                try { nm = p.ProcessName; } catch { }
                try { mb = (ulong)(p.WorkingSet64 / 1048576L); } catch { }
                try { p.Dispose(); } catch { }
                if (string.IsNullOrEmpty(nm) || mb < 15) continue;
                ulong cur;
                if (agg.TryGetValue(nm, out cur)) agg[nm] = cur + mb;
                else agg[nm] = mb;
            }
        }
        catch { }

        list = agg.OrderByDescending(x => x.Value).Take(120).ToList();

        grid.Rows.Clear();
        ulong sum = 0;
        foreach (KeyValuePair<string, ulong> kv in list)
        {
            Impact im = ImpactDb.Get(kv.Key);
            int idx = grid.Rows.Add();
            DataGridViewRow row = grid.Rows[idx];
            bool chk = preChecked.Contains(kv.Key);
            if (im.Level == ImpactLevel.Danger) chk = false;
            row.Cells["colCheck"].Value = chk;
            row.Cells["colName"].Value = kv.Key;
            row.Cells["colMem"].Value = kv.Value + " MB";
            row.Cells["colLv"].Value = ImpactDb.LevelText(im.Level);
            row.Cells["colDesc"].Value = im.Desc;
            row.Tag = kv.Key;
            if (chk) sum += kv.Value;
        }
        lblMemSummary.Text = "共 " + list.Count + " 个进程  ·  当前勾选预计释放约 " + sum + " MB";
        Cursor = Cursors.Default;
    }

    void OnCellValueChanged(object sender, DataGridViewCellEventArgs e)
    {
        if (e.RowIndex < 0 || grid.Columns[e.ColumnIndex].Name != "colCheck") return;
        DataGridViewRow row = grid.Rows[e.RowIndex];
        string name = Convert.ToString(row.Cells["colName"].Value);
        bool want = row.Cells["colCheck"].Value is bool && (bool)row.Cells["colCheck"].Value;
        if (want)
        {
            Impact im = ImpactDb.Get(name);
            if (im.Level == ImpactLevel.Danger)
            {
                row.Cells["colCheck"].Value = false;
                MessageBox.Show(this, string.Format("「{0}」属于高影响进程：{1}\n\n关闭它可能导致系统或游戏异常，已被自动取消勾选。",
                    name, im.Desc), "已保护", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (im.Level == ImpactLevel.Warn)
            {
                if (MessageBox.Show(this, string.Format("「{0}」{1}\n\n仍要加入游戏时自动关闭列表吗？",
                    name, im.Desc), "确认", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                {
                    row.Cells["colCheck"].Value = false;
                    return;
                }
            }
        }
        UpdateSummary();
    }

    void UpdateSummary()
    {
        ulong sum = 0;
        int n = 0;
        foreach (DataGridViewRow row in grid.Rows)
        {
            if (row.Cells["colCheck"].Value is bool && (bool)row.Cells["colCheck"].Value)
            {
                n++;
                string mem = Convert.ToString(row.Cells["colMem"].Value).Replace(" MB", "");
                ulong v = 0;
                ulong.TryParse(mem, out v);
                sum += v;
            }
        }
        lblMemSummary.Text = string.Format("已勾选 {0} 个  ·  预计游戏开始时可释放约 {1} MB", n, sum);
    }

    // ------------------------------------------------------------
    void SaveAndClose()
    {
        if (string.IsNullOrWhiteSpace(txtPath.Text))
        {
            MessageBox.Show(this, "请填写平台 exe 路径，或点击「自动探测」。", "缺少配置", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            tabs.SelectedIndex = 0;
            return;
        }
        if (!File.Exists(txtPath.Text.Trim()))
        {
            MessageBox.Show(this, "该路径不存在：\n" + txtPath.Text.Trim(), "路径错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            tabs.SelectedIndex = 0;
            return;
        }
        if (string.IsNullOrWhiteSpace(txtGame.Text))
        {
            MessageBox.Show(this, "请填写游戏进程名。", "缺少配置", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            tabs.SelectedIndex = 0;
            return;
        }
        if (cmbAffinity.SelectedIndex == 2 && string.IsNullOrWhiteSpace(txtMask.Text))
        {
            MessageBox.Show(this, "自定义模式需要填写十六进制掩码，例如 FFFC。", "缺少掩码", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            tabs.SelectedIndex = 0;
            return;
        }

        AppConfig c = new AppConfig();
        c.PlatformPath = txtPath.Text.Trim();
        c.GameProcessName = txtGame.Text.Trim().ToLower();
        c.Cs2Affinity = cmbAffinity.SelectedIndex == 0 ? "Exclude01" : (cmbAffinity.SelectedIndex == 1 ? "All" : "Custom");
        c.CustomMask = txtMask.Text.Trim().ToUpper();
        c.Cs2Priority = cmbPriority.SelectedIndex == 0 ? "AboveNormal" : (cmbPriority.SelectedIndex == 1 ? "High" : "Normal");
        c.PlatCoresCount = (int)numCores.Value;
        c.IntervalMs = (int)numInterval.Value;
        c.LogMaxMb = (int)numLog.Value;
        c.AutoLaunchPlatform = chkAuto.Checked;
        c.ClearLogAfterGame = chkClearLog.Checked;
        c.GameKillApps = new List<string>();
        foreach (DataGridViewRow row in grid.Rows)
        {
            if (row.Cells["colCheck"].Value is bool && (bool)row.Cells["colCheck"].Value)
            {
                string nm = Convert.ToString(row.Cells["colName"].Value);
                if (!string.IsNullOrEmpty(nm)) c.GameKillApps.Add(nm);
            }
        }

        Result = c;
        DialogResult = DialogResult.OK;
        Close();
    }
}
