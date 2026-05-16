--[[
    MacLib_Patch_Reserve.lua
    
    Патч для MacLib, решающий проблему асинхронного порядка элементов.
    
    ПРОБЛЕМА:
        Когда элементы создаются внутри task.defer / Preloader'а, они получают
        LayoutOrder от nextOrder() В МОМЕНТ СОЗДАНИЯ — то есть уже после того,
        как синхронные элементы (Divider, Header, кнопки) успели занять свои
        номера. Это делает deferred-элементы "последними" вне зависимости от
        того, где они должны стоять в интерфейсе.
    
    РЕШЕНИЕ:
        Section:Reserve(count) — вызывается синхронно, сразу резервирует
        нужное количество LayoutOrder-слотов (создавая невидимые placeholder'ы),
        и возвращает объект Reservation с методами :Fill() и :Cancel().
    
        :Fill(builderFn) — принимает функцию, которая создаёт ОДИН элемент
        (вызывая любой секций-метод). Находит только что созданный элемент
        по его frame и назначает ему зарезервированный LayoutOrder,
        после чего удаляет placeholder.
    
        :Cancel() — если элемент не нужен (ошибка загрузки), освобождает слот.
    
    ИСПОЛЬЗОВАНИЕ:
    
        -- Синхронно, до любых task.defer:
        local reservation = dR:Reserve(3)  -- бронируем 3 слота подряд
        
        -- Асинхронно, внутри task.defer / Preloader:
        task.defer(function()
            reservation:Fill(function(sec) return sec:ProgressBar({...}) end)
            reservation:Fill(function(sec) return sec:ProgressBar({...}) end)
            reservation:Fill(function(sec) return sec:Slider({...})    end)
        end)
    
    ПОДКЛЮЧЕНИЕ:
        Загрузите этот файл ПОСЛЕ загрузки MacLib, до создания Window:
        
            local MacLib = loadstring(...)()
            loadstring(game:HttpGet("<url>/MacLib_Patch_Reserve.lua"))()
        
        Или напрямую через require / dofile если файл локальный.
]]

-- ══════════════════════════════════════════════════════════════════════════════
-- Ищем MacLib в глобальном окружении
-- Патч должен применяться к уже существующему MacLib
-- ══════════════════════════════════════════════════════════════════════════════
local MacLib = _G.MacLib
assert(MacLib, "[MacLib_Patch_Reserve] MacLib не найден в _G. Убедитесь что патч загружается ПОСЛЕ MacLib.")

-- ══════════════════════════════════════════════════════════════════════════════
-- Утилита: найти последний добавленный дочерний Frame в секции
-- ══════════════════════════════════════════════════════════════════════════════
local function findNewestFrame(section, beforeSnapshot)
    -- beforeSnapshot — таблица имён/адресов фреймов ДО создания нового элемента
    -- Ищем тот Frame, которого не было до вызова builderFn
    for _, child in ipairs(section:GetChildren()) do
        if child:IsA("Frame") and not beforeSnapshot[child] then
            return child
        end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- Основная логика патча: добавляем Section:Reserve(count) через PatchSection
-- ══════════════════════════════════════════════════════════════════════════════
MacLib:PatchSection("Reserve", function(self, count)
    count = count or 1
    assert(type(count) == "number" and count >= 1,
        "[MacLib Reserve] count должен быть числом >= 1, получено: " .. tostring(count))
    
    -- self — это SectionFunctions, self._frame — сам Frame секции
    local section = self._frame
    assert(section and section:IsA("Frame"),
        "[MacLib Reserve] SectionFunctions._frame не является Frame. " ..
        "Проверьте что MacLib поддерживает _frame на секциях.")

    -- ── Создаём placeholder-фреймы, резервируя LayoutOrder-слоты ─────────────
    -- Вызываем nextOrder() через self.nextOrder — он уже exposed в MacLib
    local placeholders = {}
    for i = 1, count do
        local placeholder = Instance.new("Frame")
        placeholder.Name               = "_ReservedSlot_" .. i
        placeholder.BackgroundTransparency = 1
        placeholder.BorderSizePixel    = 0
        placeholder.AutomaticSize      = Enum.AutomaticSize.Y
        placeholder.Size               = UDim2.new(1, 0, 0, 0)
        -- Берём следующий LayoutOrder через exposed nextOrder функцию секции
        placeholder.LayoutOrder        = self.nextOrder()
        placeholder.Parent             = section
        table.insert(placeholders, placeholder)
    end

    -- ── Объект бронирования ───────────────────────────────────────────────────
    local Reservation = {}
    Reservation._placeholders = placeholders
    Reservation._fillIndex    = 1  -- следующий незаполненный слот
    Reservation._section      = self
    Reservation._sectionFrame = section

    --[[
        :Fill(builderFn)
        
        builderFn получает SectionFunctions (self) и должен создать ровно
        ОДИН элемент, вернув его объект (необязательно — используется для
        удобства при работе с результатом).
        
        Fill автоматически:
            1. Делает снимок текущих дочерних элементов секции
            2. Вызывает builderFn — элемент создаётся с nextOrder() = какой-то
               большой номер (позже всех существующих)
            3. Находит новый Frame, который появился в секции
            4. Переставляет его LayoutOrder на зарезервированный слот
            5. Удаляет соответствующий placeholder
    ]]
    function Reservation:Fill(builderFn)
        assert(type(builderFn) == "function",
            "[MacLib Reserve:Fill] builderFn должна быть функцией")
        assert(self._fillIndex <= #self._placeholders,
            "[MacLib Reserve:Fill] Все слоты уже заполнены. " ..
            "Reserve было вызвано с count=" .. #self._placeholders ..
            " но Fill вызван " .. self._fillIndex .. " раз")

        local placeholder = self._placeholders[self._fillIndex]
        local reservedOrder = placeholder.LayoutOrder

        -- Снимок ВСЕХ существующих Frame-детей ДО создания нового элемента
        local snapshot = {}
        for _, child in ipairs(self._sectionFrame:GetChildren()) do
            if child:IsA("Frame") then
                snapshot[child] = true
            end
        end

        -- Создаём элемент — он попадёт в конец (nextOrder() даст большой номер)
        local result = builderFn(self._section)

        -- Ищем новый Frame который появился после вызова builderFn
        local newFrame = findNewestFrame(self._sectionFrame, snapshot)

        if newFrame then
            -- Подменяем LayoutOrder на зарезервированный
            newFrame.LayoutOrder = reservedOrder
        else
            -- Элемент мог не создать top-level Frame (кастомный элемент)
            -- В этом случае ищем по известным именам типов элементов MacLib
            local knownNames = {
                "Button", "Toggle", "Slider", "Input", "Dropdown",
                "Keybind", "Colorpicker", "Header", "Label", "SubLabel",
                "Paragraph", "Divider", "Spacer",
                -- Кастомные (из Preloader'ов):
                "ProgressBar", "CheckBox",
            }
            -- Ищем самый последний фрейм с известным именем без слота в snapshot
            for _, child in ipairs(self._sectionFrame:GetChildren()) do
                if child:IsA("Frame") and not snapshot[child] then
                    child.LayoutOrder = reservedOrder
                    newFrame = child
                    break
                end
            end
        end

        -- Удаляем placeholder — слот занят реальным элементом
        placeholder:Destroy()
        self._fillIndex = self._fillIndex + 1

        return result
    end

    --[[
        :Cancel(slots)
        
        Отменяет оставшиеся незаполненные слоты (или конкретное количество).
        Используется при ошибке загрузки Preloader'а чтобы не оставлять
        пустые невидимые дыры в секции.
        
        slots — необязательно, число. Если не указано — отменяет все оставшиеся.
    ]]
    function Reservation:Cancel(slots)
        local toCancel = slots or (#self._placeholders - self._fillIndex + 1)
        for i = 1, toCancel do
            local ph = self._placeholders[self._fillIndex]
            if ph then
                ph:Destroy()
                self._fillIndex = self._fillIndex + 1
            end
        end
    end

    --[[
        :Remaining()
        
        Возвращает количество ещё не заполненных слотов.
    ]]
    function Reservation:Remaining()
        return #self._placeholders - self._fillIndex + 1
    end

    return Reservation
end)

print("[MacLib_Patch_Reserve] Патч успешно применён. Section:Reserve(count) доступен.")
